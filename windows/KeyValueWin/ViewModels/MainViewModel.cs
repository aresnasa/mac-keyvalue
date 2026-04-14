using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using KeyValueWin.Models;
using KeyValueWin.Services;
using Microsoft.Win32;

namespace KeyValueWin.ViewModels;

public partial class MainViewModel : ObservableObject
{
    private readonly StorageService    _storage    = StorageService.Shared;
    private readonly EncryptionService _encryption = EncryptionService.Shared;
    private readonly ImportExportService _impexp   = ImportExportService.Shared;

    // ── Collections ───────────────────────────────────────────────────────────

    public ObservableCollection<KeyValueEntry> Entries       { get; } = [];
    public ObservableCollection<KeyValueEntry> FilteredEntries { get; } = [];

    // ── Observable properties ─────────────────────────────────────────────────

    [ObservableProperty] private KeyValueEntry? _selectedEntry;
    [ObservableProperty] private string _searchQuery = string.Empty;
    [ObservableProperty] private string _statusMessage = string.Empty;
    [ObservableProperty] private bool _isStatusVisible;
    [ObservableProperty] private string _decryptedValue = string.Empty;
    [ObservableProperty] private bool _isDecrypted;

    // ── Filter / sort state (matches Mac) ─────────────────────────────────────

    [ObservableProperty] private string _selectedCategory = "all";
    [ObservableProperty] private string _selectedGroup = "all";
    [ObservableProperty] private string _sortOrder = "date_updated_desc";
    [ObservableProperty] private bool _showFavoritesOnly;
    [ObservableProperty] private bool _showPrivateOnly;
    [ObservableProperty] private bool _isPrivacyMode;

    // ── Recovery mode ─────────────────────────────────────────────────────────

    [ObservableProperty] private bool _isDataRecovery;
    [ObservableProperty] private string _recoveryReason = string.Empty;
    [ObservableProperty] private string _recoveryDataFolder = string.Empty;

    partial void OnSearchQueryChanged(string value) => ApplyFilter();
    partial void OnSelectedCategoryChanged(string value) => ApplyFilter();
    partial void OnSelectedGroupChanged(string value) => ApplyFilter();
    partial void OnSortOrderChanged(string value) => ApplyFilter();
    partial void OnShowFavoritesOnlyChanged(bool value) => ApplyFilter();
    partial void OnShowPrivateOnlyChanged(bool value) => ApplyFilter();

    /// <summary>All distinct non-empty group names, for the Group filter dropdown.</summary>
    public IReadOnlyList<string> AllGroups
    {
        get
        {
            return Entries
                .Where(e => !string.IsNullOrWhiteSpace(e.Group))
                .Select(e => e.Group)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(g => g, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
    }

    // ── Initialization ────────────────────────────────────────────────────────

    /// <summary>
    /// Phase-based bootstrap that isolates failures so a damaged key or
    /// corrupt data file never silently overwrites good data.
    /// </summary>
    public void Initialize()
    {
        // Phase 1 – detect existing data before touching the key
        var hasData = _storage.HasExistingEntriesFile;

        // Phase 2 – verify the master key (throws if key lost & data exists)
        try
        {
            _encryption.EnsureMasterKey(storageHasExistingData: hasData);
        }
        catch (MasterKeyLostWithExistingDataException)
        {
            EnterRecoveryMode(
                "加密主密钥丢失。\n\n" +
                "您的加密数据仍存在于磁盘上，但没有原始 DPAPI 密钥无法解密这些条目。" +
                "创建新密钥将销毁所有数据。\n\n" +
                "可选操作：\n" +
                "  • 从备份恢复 master.key 文件\n" +
                "  • 重置所有数据重新开始（条目将丢失）");
            return;
        }

        // Phase 3 – load data
        try
        {
            _storage.Load();
        }
        catch (StorageLoadException ex)
        {
            EnterRecoveryMode(
                $"数据文件无法读取 — 所有副本（包括备份）均已损坏。\n\n" +
                $"技术详情: {ex.Message}\n\n" +
                "可选操作：\n" +
                "  • 打开数据目录手动恢复备份\n" +
                "  • 重置所有数据重新开始");
            return;
        }

        // Phase 4 – success
        ReloadEntries();
    }

    private void EnterRecoveryMode(string reason)
    {
        IsDataRecovery = true;
        RecoveryReason = reason;
        RecoveryDataFolder = StorageService.DataDirectory;
    }

    // ── Recovery commands ─────────────────────────────────────────────────────

    [RelayCommand]
    private void OpenDataFolder()
    {
        try { Process.Start("explorer.exe", StorageService.DataDirectory); }
        catch (Exception ex) { ShowStatus($"无法打开文件夹: {ex.Message}"); }
    }

    [RelayCommand]
    private void RetryInitialize()
    {
        IsDataRecovery = false;
        RecoveryReason = string.Empty;
        Initialize();
    }

    [RelayCommand]
    private void PerformDataReset()
    {
        var result = MessageBox.Show(
            "这将永久删除所有已存储的条目和加密主密钥。\n\n" +
            "此操作无法撤销。\n\n确定要继续吗？",
            "确认数据重置",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (result != MessageBoxResult.Yes) return;

        try
        {
            _storage.DeleteAllFiles();
            _encryption.DeleteMasterKey();
            IsDataRecovery = false;
            RecoveryReason = string.Empty;
            Entries.Clear();
            FilteredEntries.Clear();
            Initialize();
            ShowStatus("所有数据已重置，新的加密密钥已创建。");
        }
        catch (Exception ex)
        {
            MessageBox.Show($"重置失败: {ex.Message}", "错误",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void ReloadEntries()
    {
        Entries.Clear();
        foreach (var e in _storage.GetAll()) Entries.Add(e);
        OnPropertyChanged(nameof(AllGroups));
        ApplyFilter();
    }

    private void ApplyFilter()
    {
        FilteredEntries.Clear();
        var q = SearchQuery.Trim();

        // Start from search results or all entries
        IEnumerable<KeyValueEntry> source = string.IsNullOrEmpty(q)
            ? Entries
            : _storage.Search(q).AsEnumerable();

        // Category filter
        if (SelectedCategory != "all")
            source = source.Where(e => e.Category == SelectedCategory);

        // Group filter
        if (SelectedGroup != "all")
            source = source.Where(e => e.Group.Equals(SelectedGroup, StringComparison.OrdinalIgnoreCase));

        // Favorites only
        if (ShowFavoritesOnly)
            source = source.Where(e => e.IsFavorite);

        // Private only
        if (ShowPrivateOnly)
            source = source.Where(e => e.IsPrivate);

        // Sort
        source = SortOrder switch
        {
            "title_asc"          => source.OrderBy(e => e.Title, StringComparer.OrdinalIgnoreCase),
            "title_desc"         => source.OrderByDescending(e => e.Title, StringComparer.OrdinalIgnoreCase),
            "date_created_desc"  => source.OrderByDescending(e => e.CreatedAt),
            "date_created_asc"   => source.OrderBy(e => e.CreatedAt),
            "date_updated_desc"  => source.OrderByDescending(e => e.UpdatedAt),
            "date_updated_asc"   => source.OrderBy(e => e.UpdatedAt),
            "usage_desc"         => source.OrderByDescending(e => e.UsageCount),
            "usage_asc"          => source.OrderBy(e => e.UsageCount),
            _                    => source.OrderByDescending(e => e.UpdatedAt),
        };

        foreach (var e in source) FilteredEntries.Add(e);
    }


    // ── Commands ──────────────────────────────────────────────────────────────

    [RelayCommand]
    private void CopyValue()
    {
        if (SelectedEntry is null) return;
        try
        {
            var val = _encryption.DecryptToString(SelectedEntry.EncryptedValue);
            Clipboard.SetText(val);
            ShowStatus("已复制到剪贴板");
            // Clear after 30s
            Task.Delay(30_000).ContinueWith(_ =>
                Application.Current.Dispatcher.Invoke(() =>
                {
                    if (Clipboard.GetText() == val) Clipboard.Clear();
                }));
        }
        catch (Exception ex) { ShowStatus($"错误: {ex.Message}"); }
    }

    [RelayCommand]
    private void DecryptValue()
    {
        if (SelectedEntry is null) return;
        try
        {
            DecryptedValue = _encryption.DecryptToString(SelectedEntry.EncryptedValue);
            IsDecrypted = true;
        }
        catch (Exception ex) { ShowStatus($"解密失败: {ex.Message}"); }
    }

    [RelayCommand]
    private void HideValue()
    {
        DecryptedValue = string.Empty;
        IsDecrypted = false;
    }

    [RelayCommand]
    private void DeleteEntry()
    {
        if (SelectedEntry is null) return;
        if (MessageBox.Show($"确定删除 '{SelectedEntry.Title}'?", "确认",
                MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        _storage.Delete(SelectedEntry.Id);
        ReloadEntries();
        SelectedEntry = null;
        IsDecrypted = false;
        ShowStatus("条目已删除");
    }

    [RelayCommand]
    private void ToggleFavorite()
    {
        if (SelectedEntry is null) return;
        SelectedEntry.IsFavorite = !SelectedEntry.IsFavorite;
        _storage.Upsert(SelectedEntry);
        ReloadEntries();
        ShowStatus(SelectedEntry.IsFavorite ? "已添加收藏" : "已取消收藏");
    }

    [RelayCommand]
    private void CopyKey()
    {
        if (SelectedEntry is null || string.IsNullOrEmpty(SelectedEntry.Key)) return;
        Clipboard.SetText(SelectedEntry.Key);
        ShowStatus("用户名已复制到剪贴板");
    }

    [RelayCommand]
    private void TogglePrivacyMode()
    {
        IsPrivacyMode = !IsPrivacyMode;
        ShowStatus(IsPrivacyMode ? "隐私模式已开启" : "隐私模式已关闭");
    }

    [RelayCommand]
    private void ResetFilters()
    {
        SearchQuery = string.Empty;
        SelectedCategory = "all";
        SelectedGroup = "all";
        ShowFavoritesOnly = false;
        ShowPrivateOnly = false;
        SortOrder = "date_updated_desc";
    }

    // ── Import ────────────────────────────────────────────────────────────────

    [RelayCommand]
    private void ImportFile()
    {
        var dlg = new OpenFileDialog
        {
            Title = "导入条目",
            Filter = "所有支持格式|*.json;*.csv;*.txt;*.mkve|MacKeyValue JSON|*.json|" +
                     "MacKeyValue 加密文件|*.mkve|CSV|*.csv;*.txt|所有文件|*.*"
        };
        if (dlg.ShowDialog() != true) return;

        string? password = null;
        var ext = Path.GetExtension(dlg.FileName).ToLowerInvariant();
        if (ext == ".mkve")
        {
            var pwdDlg = new Views.PasswordDialog("请输入导出密码:");
            if (pwdDlg.ShowDialog() != true) return;
            password = pwdDlg.Password;
        }

        try
        {
            var (entries, summary) = _impexp.ImportFromFile(dlg.FileName, password);
            _storage.BulkInsert(entries);
            ReloadEntries();
            ShowStatus(summary);
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "导入错误", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    // ── Export ────────────────────────────────────────────────────────────────

    [RelayCommand]
    private void ExportJson()  => DoExport(encrypted: false);

    [RelayCommand]
    private void ExportEncrypted() => DoExport(encrypted: true);

    [RelayCommand]
    private void ExportCsv()
    {
        var dlg = new SaveFileDialog
        {
            Title = "导出为 CSV",
            Filter = "CSV|*.csv",
            FileName = $"mackeyvalue-export-{DateTime.Now:yyyyMMdd-HHmmss}.csv"
        };
        if (dlg.ShowDialog() != true) return;
        try
        {
            File.WriteAllBytes(dlg.FileName, _impexp.ExportToCsv(_storage.GetAll()));
            ShowStatus($"已导出 {_storage.Count} 条记录到 CSV");
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "导出错误", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void DoExport(bool encrypted)
    {
        string? password = null;
        if (encrypted)
        {
            var pwdDlg = new Views.PasswordDialog("设置导出密码（导入时需要）:");
            if (pwdDlg.ShowDialog() != true) return;
            password = pwdDlg.Password;
        }
        var ext = encrypted ? "mkve" : "json";
        var dlg = new SaveFileDialog
        {
            Title  = encrypted ? "导出加密文件" : "导出 JSON",
            Filter = encrypted ? "加密文件|*.mkve" : "JSON|*.json",
            FileName = $"mackeyvalue-export-{DateTime.Now:yyyyMMdd-HHmmss}.{ext}"
        };
        if (dlg.ShowDialog() != true) return;
        try
        {
            var data = encrypted && password is not null
                ? _impexp.ExportToEncryptedJson(_storage.GetAll(), password)
                : _impexp.ExportToJson(_storage.GetAll());
            File.WriteAllBytes(dlg.FileName, data);
            ShowStatus($"已导出 {_storage.Count} 条记录");
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "导出错误", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    // ── Status ────────────────────────────────────────────────────────────────

    private CancellationTokenSource? _statusCts;

    private void ShowStatus(string msg)
    {
        _statusCts?.Cancel();
        StatusMessage = msg;
        IsStatusVisible = true;
        _statusCts = new CancellationTokenSource();
        var tok = _statusCts.Token;
        Task.Delay(3_000, tok).ContinueWith(_ =>
        {
            if (!tok.IsCancellationRequested)
                Application.Current.Dispatcher.Invoke(() => IsStatusVisible = false);
        }, tok);
    }
}
