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
}

public class Experiment
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Baseline { get; set; } = "";
    public int TaskNumber { get; set; }
    public int AttemptNumber { get; set; }
    public string Prompt { get; set; } = "";
    public DateTime CreatedAtUtc { get; set; } = DateTime.UtcNow;
    public List<Command> Commands { get; set; } = new();
    public List<Run> Runs { get; set; } = new();
}

public class Store
{
    public List<Machine> Machines { get; set; } = new();
    public List<Experiment> Experiments { get; set; } = new();
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
