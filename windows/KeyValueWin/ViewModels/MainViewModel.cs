using System.Collections.ObjectModel;
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

    partial void OnSearchQueryChanged(string value) => ApplyFilter();

    // ── Initialization ────────────────────────────────────────────────────────

    public void Initialize()
    {
        _storage.Load();
        ReloadEntries();
    }

    private void ReloadEntries()
    {
        Entries.Clear();
        foreach (var e in _storage.GetAll()) Entries.Add(e);
        ApplyFilter();
    }

    private void ApplyFilter()
    {
        FilteredEntries.Clear();
        var q = SearchQuery.Trim();
        var source = string.IsNullOrEmpty(q) ? Entries : _storage.Search(q).AsEnumerable();
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
            ShowStatus("Copied to clipboard");
            // Clear after 30s
            Task.Delay(30_000).ContinueWith(_ =>
                Application.Current.Dispatcher.Invoke(() =>
                {
                    if (Clipboard.GetText() == val) Clipboard.Clear();
                }));
        }
        catch (Exception ex) { ShowStatus($"Error: {ex.Message}"); }
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
        catch (Exception ex) { ShowStatus($"Decrypt failed: {ex.Message}"); }
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
        if (MessageBox.Show($"Delete '{SelectedEntry.Title}'?", "Confirm",
                MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        _storage.Delete(SelectedEntry.Id);
        ReloadEntries();
        SelectedEntry = null;
        IsDecrypted = false;
        ShowStatus("Entry deleted");
    }

    [RelayCommand]
    private void ToggleFavorite()
    {
        if (SelectedEntry is null) return;
        SelectedEntry.IsFavorite = !SelectedEntry.IsFavorite;
        _storage.Upsert(SelectedEntry);
        ReloadEntries();
        ShowStatus(SelectedEntry.IsFavorite ? "Added to favorites" : "Removed from favorites");
    }

    // ── Import ────────────────────────────────────────────────────────────────

    [RelayCommand]
    private void ImportFile()
    {
        var dlg = new OpenFileDialog
        {
            Title = "Import Entries",
            Filter = "All Supported|*.json;*.csv;*.txt;*.mkve|MacKeyValue JSON|*.json|" +
                     "MacKeyValue Encrypted|*.mkve|CSV|*.csv;*.txt|All Files|*.*"
        };
        if (dlg.ShowDialog() != true) return;

        string? password = null;
        var ext = Path.GetExtension(dlg.FileName).ToLowerInvariant();
        if (ext == ".mkve")
        {
            var pwdDlg = new Views.PasswordDialog("Enter export password:");
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
        catch (Exception ex) { MessageBox.Show(ex.Message, "Import Error", MessageBoxButton.OK, MessageBoxImage.Error); }
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
            Title = "Export as CSV",
            Filter = "CSV|*.csv",
            FileName = $"mackeyvalue-export-{DateTime.Now:yyyyMMdd-HHmmss}.csv"
        };
        if (dlg.ShowDialog() != true) return;
        try
        {
            File.WriteAllBytes(dlg.FileName, _impexp.ExportToCsv(_storage.GetAll()));
            ShowStatus($"Exported {_storage.Count} entries to CSV");
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Export Error", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void DoExport(bool encrypted)
    {
        string? password = null;
        if (encrypted)
        {
            var pwdDlg = new Views.PasswordDialog("Set export password (required to import):");
            if (pwdDlg.ShowDialog() != true) return;
            password = pwdDlg.Password;
        }
        var ext = encrypted ? "mkve" : "json";
        var dlg = new SaveFileDialog
        {
            Title  = encrypted ? "Export Encrypted" : "Export JSON",
            Filter = encrypted ? "Encrypted|*.mkve" : "JSON|*.json",
            FileName = $"mackeyvalue-export-{DateTime.Now:yyyyMMdd-HHmmss}.{ext}"
        };
        if (dlg.ShowDialog() != true) return;
        try
        {
            var data = encrypted && password is not null
                ? _impexp.ExportToEncryptedJson(_storage.GetAll(), password)
                : _impexp.ExportToJson(_storage.GetAll());
            File.WriteAllBytes(dlg.FileName, data);
            ShowStatus($"Exported {_storage.Count} entries");
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Export Error", MessageBoxButton.OK, MessageBoxImage.Error); }
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
