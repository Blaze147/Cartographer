using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cartographer;

// ---- Persistence model ------------------------------------------------

public class Machine
{
    public string MachineId { get; set; } = "";
    public string? Harness { get; set; }
    public string? RepositoryPath { get; set; }
    public string? Branch { get; set; }
    public string State { get; set; } = "Idle";
    public string? LastError { get; set; }
    public DateTime? LastHeartbeatUtc { get; set; }
}

public class Command
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string MachineId { get; set; } = "";
    public string Type { get; set; } = ""; // "prepare" | "collect"
    public string? Baseline { get; set; }
    public int TaskNumber { get; set; }
    public int AttemptNumber { get; set; }
    public string? Prompt { get; set; }
    public string? BranchName { get; set; }
    public string State { get; set; } = "Pending"; // Pending | Acknowledged | Complete | Failed
    public string? Error { get; set; }
}

public class Run
{
    public string MachineId { get; set; } = "";
    public string? Harness { get; set; }
    public string? Branch { get; set; }
    public string? Baseline { get; set; }
    public int TaskNumber { get; set; }
    public int AttemptNumber { get; set; }
    public string? CommitSha { get; set; }
    public int FilesChanged { get; set; }
    public int FilesAdded { get; set; }
    public int FilesModified { get; set; }
    public int FilesDeleted { get; set; }
    public int LinesAdded { get; set; }
    public int LinesDeleted { get; set; }
    public int RenameCount { get; set; }
    public List<string> ChangedFiles { get; set; } = new();
    public string? Diff { get; set; }
    public DateTime? CollectedAtUtc { get; set; }

    // Manually entered fields.
    public string Completion { get; set; } = ""; // Completed | Aborted
    public double? Score { get; set; }
    public string? ElapsedTime { get; set; }
    public string? Tokens { get; set; }
    public string? Notes { get; set; }

    // Model used for this run, picked in the web UI on the experiment header
    // and copied to every run whose harness allows a free model choice. Null
    // for runs on proprietary-model harnesses (Claude Code, Codex) — see
    // ModelAppliesTo in Program.cs — and until a model has been picked.
    public string? Model { get; set; }

    // Live agent state mirrored from the machine's latest heartbeat (Idle,
    // Preparing, Ready, Working, Collecting, ...). Distinct from Completion:
    // this is what the local agent itself is doing right now.
    public string? AgentState { get; set; }
}

public class Experiment
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Baseline { get; set; } = "";
    public int TaskNumber { get; set; }
    public int AttemptNumber { get; set; }
    public string Prompt { get; set; } = "";
    public DateTime CreatedAtUtc { get; set; } = DateTime.UtcNow;

    // Model chosen in the web UI for this experiment (the catalog entry that
    // went into every model-eligible run row; see Run.Model). Null until the
    // user picks one.
    public string? Model { get; set; }

    // Optional human-written title. When set, the card header shows this
    // instead of the "Baseline · Task N · Attempt N" default; the underlying
    // fields stay intact and are surfaced in the title tooltip.
    public string? CustomTitle { get; set; }

    public List<Command> Commands { get; set; } = new();
    public List<Run> Runs { get; set; } = new();
}

public class Store
{
    public List<Machine> Machines { get; set; } = new();
    public List<Experiment> Experiments { get; set; } = new();

    // The model "enum": catalog of selectable model names, managed from the
    // web UI. Entries are referenced by experiments/runs by display name.
    public List<string> Models { get; set; } = new();
}

// ---- JSON-file persistence -------------------------------------------

public class Persistence
{
    private readonly string _path;
    private Store _store = new();

    public Persistence(string path)
    {
        _path = path;
    }

    public Store Load()
    {
        // The persistent volume may be fresh, so first make sure its directory
        // exists — a second compute node starting on an empty store should not
        // crash before the first Save() runs.
        var dir = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        if (File.Exists(_path))
        {
            try
            {
                _store = JsonSerializer.Deserialize<Store>(File.ReadAllText(_path))
                         ?? new Store();
            }
            catch
            {
                // Corrupt data should not silently hide experiments; fail visibly.
                throw new InvalidOperationException(
                    $"Could not parse data file at {_path}. Fix or remove it, then restart.");
            }
        }
        return _store;
    }

    public void Save(Store store)
    {
        _store = store;
        var dir = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        // Safe write: serialize to a temp file, then atomically replace.
        var tmp = _path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(store, new JsonSerializerOptions
        {
            WriteIndented = true
        }));
        File.Move(tmp, _path, overwrite: true);
    }
}
