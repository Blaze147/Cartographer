using System.Text.Json;
using Cartographer;

var builder = WebApplication.CreateBuilder(args);

// Serve the static frontend from wwwroot.
builder.WebHost.UseWebRoot(Path.Combine(builder.Environment.ContentRootPath, "wwwroot"));

// Read configuration from environment / appsettings.
string dataPath = Environment.GetEnvironmentVariable("CARTOGRAPHER_DATA") ?? "data.json";
string apiKey = Environment.GetEnvironmentVariable("CARTOGRAPHER_API_KEY") ?? "";
int offlineSeconds = int.Parse(Environment.GetEnvironmentVariable("CARTOGRAPHER_OFFLINE_SECONDS") ?? "90");
string webPassword = Environment.GetEnvironmentVariable("CARTOGRAPHER_WEB_PASSWORD") ?? "";

var app = builder.Build();

var persistence = new Persistence(dataPath);
var store = persistence.Load();

app.UseDefaultFiles();
app.UseStaticFiles();

// ---- Helpers ----------------------------------------------------------

bool Authorized(HttpRequest req) =>
    apiKey.Length == 0 || (req.Headers["X-Api-Key"].FirstOrDefault() == apiKey);

bool WebAuthorized(HttpRequest req) =>
    webPassword.Length == 0 || (req.Headers["Cookie"].FirstOrDefault() ?? "").Contains("cartographer_auth=");

// Build the branch name consistently across all machines, e.g. baseline
// "baselineB004" or "baseline/b004", task 1, attempt 1, harness
// "deepseek harness" -> "b004/task-001/deepseek_harness/01".
// Git branch names follow check-ref-format: no spaces and no leading slash,
// so whitespace in the parts (harness names especially) becomes underscores
// and separators left over from the baseline word are stripped.
static string BranchName(string baseline, int task, int attempt, string harness)
{
    var tag = baseline.Trim();
    if (tag.StartsWith("baseline", StringComparison.OrdinalIgnoreCase))
        tag = tag["baseline".Length..];
    // The new "baseline/bXXX" spelling leaves a leading separator behind.
    tag = tag.TrimStart('/');
    static string Safe(string s)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var c in s.Trim())
            sb.Append(char.IsWhiteSpace(c) ? '_' : c);
        return sb.ToString();
    }
    var t = Safe(tag).ToLowerInvariant();
    var h = Safe(harness).ToLowerInvariant();
    return $"{t}/task-{task:000}/{h}/{attempt:00}";
}

static bool IsOffline(DateTime? hb, int offlineSeconds) =>
    hb == null || (DateTime.UtcNow - hb.Value).TotalSeconds > offlineSeconds;

// ---- Model tracking ----------------------------------------------------
// Harnesses whose vendor forces their own proprietary models — the user has
// no free model choice on those, so the model picker does not apply and run
// rows there store no model at all.
static bool ModelAppliesTo(string? harness)
{
    if (string.IsNullOrWhiteSpace(harness)) return false;
    var h = harness.Trim();
    if (h.Contains("claude code", StringComparison.OrdinalIgnoreCase)) return false;
    if (h.Contains("codex", StringComparison.OrdinalIgnoreCase)) return false;
    return true;
}

// Copy an experiment's chosen model onto every run whose harness allows a
// free model choice; proprietary-harness runs always hold no model.
static void PropagateModel(Experiment exp)
{
    foreach (var run in exp.Runs)
        run.Model = ModelAppliesTo(run.Harness) ? exp.Model : null;
}

// State shown to the web UI. If the agent announced a clean shutdown
// ("Stopped"), that state stays put: the farewell heartbeat means the agent
// went down gracefully and nothing newer will arrive until it starts again.
// For every other state, silence is the only evidence we get — the machine
// crashed, lost power or lost its network — so after the offline window the
// last reported state is overridden with "Offline".
static string StateOf(Machine m, bool isOffline) =>
    (isOffline && m.State != "Stopped") ? "Offline" : m.State;

static object PublicMachine(Machine m, int offlineSeconds)
{
    bool off = IsOffline(m.LastHeartbeatUtc, offlineSeconds) && m.State != "Stopped";
    return new
    {
        m.MachineId, m.Harness, m.RepositoryPath, m.Branch,
        State = StateOf(m, off), m.LastError, m.LastHeartbeatUtc, Online = !off
    };
}

// ---- Web shell ---------------------------------------------------------

// GET / shows index.html (served by DefaultFiles).

// Returned when there is no work for an agent; agents ignore commands with no id.
var NoCommand = new Command { Id = "" };

// ---- Machine endpoints (agents) ----------------------------------------

app.MapGet("/api/agents/{machineId}/command", (string machineId, HttpRequest req) =>
{
    if (!Authorized(req)) return Results.Unauthorized();

    var m = store.Machines.FirstOrDefault(x => x.MachineId == machineId);
    if (m == null) return Results.Json(NoCommand);

    // The earliest pending command for this machine, in experiment order.
    var cmd = store.Experiments
        .OrderBy(e => e.CreatedAtUtc)
        .SelectMany(e => e.Commands
            .Where(c => c.MachineId == machineId && c.State == "Pending"))
        .FirstOrDefault();

    return Results.Json(cmd ?? NoCommand);
});

app.MapPost("/api/agents/{machineId}/heartbeat", (string machineId, Machine body, HttpRequest req) =>
{
    if (!Authorized(req)) return Results.Unauthorized();

    var m = store.Machines.FirstOrDefault(x => x.MachineId == machineId);
    if (m == null)
    {
        m = new Machine { MachineId = machineId };
        store.Machines.Add(m);
    }
    m.Harness = body.Harness;
    m.RepositoryPath = body.RepositoryPath;
    m.Branch = body.Branch;
    m.State = body.State;
    m.LastError = body.LastError;
    m.LastHeartbeatUtc = DateTime.UtcNow;

    // Keep the experiment tables live — but only for the run rows that
    // actually belong to where the agent is right now. The heartbeat carries
    // the branch the agent is currently on, so the mirror compares it against
    // each row's own branch: stale/incomplete experiments (which have their
    // own branch names) keep the state they last had when the agent left them
    // instead of riding along with whatever the agent does next.
    if (!string.IsNullOrEmpty(m.State) && !string.IsNullOrEmpty(m.Branch))
    {
        foreach (var exp in store.Experiments)
        {
            var run = exp.Runs.FirstOrDefault(r => r.MachineId == machineId
                && r.CollectedAtUtc == null
                && r.Branch == m.Branch);
            if (run != null) run.AgentState = m.State;
        }
    }
    persistence.Save(store);
    return Results.Ok();
});

// Body: { commandId, success, error, run? }
app.MapPost("/api/agents/{machineId}/command-result", (string machineId, JsonElement body, HttpRequest req) =>
{
    if (!Authorized(req)) return Results.Unauthorized();

    var cmdId = body.GetProperty("commandId").GetString() ?? "";
    var success = body.TryGetProperty("success", out var s) && s.GetBoolean();
    var err = body.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.String ? e.GetString() : null;

    var pair = store.Experiments
        .SelectMany(exp => exp.Commands.Select(c => new { exp, c }))
        .FirstOrDefault(x => x.c.Id == cmdId);
    if (pair == null) return Results.NotFound();

    pair.c.State = success ? "Complete" : "Failed";
    pair.c.Error = err;

    if (success && body.TryGetProperty("run", out var runEl) && pair.c.Type == "collect")
    {
        var run = JsonSerializer.Deserialize<Run>(runEl.GetRawText(), new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
        if (run != null)
        {
            var machine = store.Machines.FirstOrDefault(x => x.MachineId == machineId);
            run.MachineId = machineId;
            run.Harness ??= machine?.Harness;
            // Agents never report a model (it is web-UI data); make sure the
            // incoming payload cannot introduce one. Eligible harnesses keep
            // or inherit the experiment's choice below; proprietary rows (Claude
            // Code, Codex) always stay modelless.
            run.Model = null;
            var existing = pair.exp.Runs.FirstOrDefault(r => r.MachineId == machineId);
            if (existing != null)
            {
                existing.Branch = run.Branch;
                existing.CommitSha = run.CommitSha;
                existing.FilesChanged = run.FilesChanged;
                existing.FilesAdded = run.FilesAdded;
                existing.FilesModified = run.FilesModified;
                existing.FilesDeleted = run.FilesDeleted;
                existing.LinesAdded = run.LinesAdded;
                existing.LinesDeleted = run.LinesDeleted;
                existing.RenameCount = run.RenameCount;
                existing.ChangedFiles = run.ChangedFiles;
                existing.Diff = run.Diff;
                existing.CollectedAtUtc = DateTime.UtcNow;
                // The heartbeat mirror no longer touches collected rows, so
                // set the final state here; the dot shows "Collected" even
                // before the agent's follow-up heartbeat would arrive.
                existing.AgentState = "Collected";
            }
            else
            {
                run.CollectedAtUtc = DateTime.UtcNow;
                run.AgentState = "Collected";
                pair.exp.Runs.Add(run);
            }
        }
    }
    persistence.Save(store);
    return Results.Ok();
});

// ---- Model catalog endpoints (browser) ----------------------------------

app.MapGet("/api/models", (HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();
    return Results.Json(store.Models);
});

// Body: { name }. Adding is case-insensitively deduped.
app.MapPost("/api/models", (JsonElement body, HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();
    var name = body.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
    name = name.Trim();
    if (name.Length == 0) return Results.BadRequest("name is required.");
    var existing = store.Models.FirstOrDefault(m =>
        string.Equals(m, name, StringComparison.OrdinalIgnoreCase));
    if (existing == null)
    {
        store.Models.Add(name);
        persistence.Save(store);
        return Results.Ok(name);
    }
    return Results.Ok(existing);
});

app.MapDelete("/api/models/{*name}", (string name, HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();
    // Experiments keep whatever model string they were tagged with, so
    // removal only affects future pickers, never recorded data.
    var removed = store.Models.RemoveAll(m =>
        string.Equals(m, name, StringComparison.OrdinalIgnoreCase)) > 0;
    if (!removed) return Results.NotFound();
    persistence.Save(store);
    return Results.Ok();
});

// ---- Dashboard endpoints (browser) --------------------------------------

app.MapGet("/api/machines", (HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();
    return Results.Json(store.Machines.Select(m => PublicMachine(m, offlineSeconds)));
});

app.MapGet("/api/experiments", (HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();
    return Results.Json(store.Experiments.OrderByDescending(e => e.CreatedAtUtc));
});

app.MapGet("/api/experiments/{id}", (string id, HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();
    var exp = store.Experiments.FirstOrDefault(e => e.Id == id);
    return exp == null ? Results.NotFound() : Results.Json(exp);
});

// Body: { baseline, taskNumber, attemptNumber, prompt }
app.MapPost("/api/experiments/start", (JsonElement body, HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();

    var baseline = body.GetProperty("baseline").GetString() ?? "";
    var task = body.TryGetProperty("taskNumber", out var t) ? t.GetInt32() : 0;
    var attempt = body.TryGetProperty("attemptNumber", out var a) ? a.GetInt32() : 0;
    var prompt = body.TryGetProperty("prompt", out var p) ? p.GetString() ?? "" : "";
    var model = body.TryGetProperty("model", out var mo) ? mo.GetString() : null;

    if (baseline.Length == 0 || task < 1 || attempt < 1)
        return Results.BadRequest("baseline, taskNumber, and attemptNumber are required.");

    var exp = new Experiment { Baseline = baseline, TaskNumber = task, AttemptNumber = attempt, Prompt = prompt, Model = model };

    foreach (var m in store.Machines)
    {
        var harness = m.Harness ?? m.MachineId;
        var branchName = BranchName(baseline, task, attempt, harness);
        exp.Commands.Add(new Command
        {
            MachineId = m.MachineId,
            Type = "prepare",
            Baseline = baseline,
            TaskNumber = task,
            AttemptNumber = attempt,
            Prompt = prompt,
            BranchName = branchName
        });

        // Seed a placeholder run row right away so each machine's entry shows
        // up in the experiment table from the moment the experiment starts,
        // instead of only once "Complete" triggers its collect result. The
        // collect path (find-or-create) and the manual save path both target
        // an existing row by machine id, so they fill this row in in place.
        // The row carries its branch name up front, which is what the
        // heartbeat-state mirror matches on.
        if (!exp.Runs.Any(r => r.MachineId == m.MachineId))
        {
            exp.Runs.Add(new Run
            {
                MachineId = m.MachineId,
                Baseline = baseline,
                TaskNumber = task,
                AttemptNumber = attempt,
                Harness = harness,
                Branch = branchName,
                // Seed with the live machine state only if the machine is
                // actually already on this run's branch; otherwise "Pending"
                // until the heartbeat mirror takes over after prepare.
                AgentState = m.Branch == branchName ? m.State : "Pending"
            });
        }
    }
    store.Experiments.Add(exp);
    PropagateModel(exp);
    persistence.Save(store);
    return Results.Ok(exp);
});

// Pick the model for this experiment. Body: { model } (empty string = none).
// The choice lands on the experiment itself and on every run row whose
// harness allows free model choice; Claude Code / Codex rows stay modelless.
app.MapPost("/api/experiments/{id}/model", (string id, JsonElement body, HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();

    var exp = store.Experiments.FirstOrDefault(e => e.Id == id);
    if (exp == null) return Results.NotFound();

    var model = body.TryGetProperty("model", out var m) ? m.GetString() : null;
    if (string.IsNullOrWhiteSpace(model)) model = null;
    else if (!store.Models.Contains(model, StringComparer.OrdinalIgnoreCase))
        return Results.BadRequest($"Unknown model '{model}'.");

    exp.Model = model;
    PropagateModel(exp);
    persistence.Save(store);
    return Results.Ok(exp);
});

// Ask every machine to collect its run for this experiment.
app.MapPost("/api/experiments/{id}/complete", (string id, HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();

    var exp = store.Experiments.FirstOrDefault(e => e.Id == id);
    if (exp == null) return Results.NotFound();

    foreach (var m in store.Machines)
    {
        exp.Commands.Add(new Command
        {
            MachineId = m.MachineId,
            Type = "collect",
            Baseline = exp.Baseline,
            TaskNumber = exp.TaskNumber,
            AttemptNumber = exp.AttemptNumber,
            Prompt = exp.Prompt,
            BranchName = BranchName(exp.Baseline, exp.TaskNumber, exp.AttemptNumber, m.Harness ?? m.MachineId)
        });
    }
    persistence.Save(store);
    return Results.Ok(exp);
});

// Update manually entered run fields. Body is a Run with partial fields.
app.MapPost("/api/experiments/{id}/runs/{machineId}", (string id, string machineId, Run body, HttpRequest req) =>
{
    if (!WebAuthorized(req)) return Results.Unauthorized();

    var exp = store.Experiments.FirstOrDefault(e => e.Id == id);
    if (exp == null) return Results.NotFound();

    var run = exp.Runs.FirstOrDefault(r => r.MachineId == machineId);
    if (run == null)
    {
        run = new Run { MachineId = machineId };
        exp.Runs.Add(run);
    }
    run.Harness = body.Harness ?? run.Harness;
    run.Branch = body.Branch ?? run.Branch;
    run.Baseline = body.Baseline ?? exp.Baseline;
    run.TaskNumber = body.TaskNumber != 0 ? body.TaskNumber : exp.TaskNumber;
    run.AttemptNumber = body.AttemptNumber != 0 ? body.AttemptNumber : exp.AttemptNumber;
    // Run.Completion defaults to "" (non-nullable), so an update that only
    // touches other fields arrives with Completion == "" rather than null —
    // treat empty as "not provided" instead of wiping a saved value back to
    // the placeholder '—'.
    run.Completion = string.IsNullOrEmpty(body.Completion) ? run.Completion : body.Completion;
    if (body.Score.HasValue) run.Score = body.Score;
    run.ElapsedTime = body.ElapsedTime ?? run.ElapsedTime;
    run.Tokens = body.Tokens ?? run.Tokens;
    // The model is experiment-level in the UI; a run-row edit is not offered.
    // Guard anyway: proprietary harnesses can never carry a model, and an
    // eligible run without one inherits the experiment's choice.
    run.Model = !ModelAppliesTo(run.Harness) ? null
        : (!string.IsNullOrEmpty(body.Model) ? body.Model
        : (run.Model ?? (ModelAppliesTo(run.Harness) ? exp.Model : null)));
    run.Notes = body.Notes ?? run.Notes;
    persistence.Save(store);
    return Results.Ok(run);
});

app.Run();
