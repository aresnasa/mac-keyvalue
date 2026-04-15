using System.Windows;
using System.Windows.Controls;
using KeyValueWin.Models;
using KeyValueWin.Services;

namespace KeyValueWin.Views;

/// <summary>
/// Add / edit a <see cref="KeyValueEntry"/>.
/// Pass <c>null</c> to create a new entry; pass an existing entry to edit it.
/// </summary>
public partial class EntryEditWindow : Window
{
    private readonly KeyValueEntry? _original;

    // ── Constructor ───────────────────────────────────────────────────────────

    public EntryEditWindow(KeyValueEntry? entry = null)
    {
        InitializeComponent();
        _original = entry;

        if (entry is not null)
            PopulateFields(entry);
        else
            TitleLabel.Text = "新建条目";
    }

    // ── Field population ──────────────────────────────────────────────────────

    private void PopulateFields(KeyValueEntry entry)
    {
        TitleLabel.Text   = "编辑条目";
        Title             = "编辑条目";
        TxtTitle.Text     = entry.Title;
        TxtKey.Text       = entry.Key;
        TxtUrl.Text       = entry.Url;
        TxtGroup.Text     = entry.Group;
        TxtNotes.Text     = entry.Notes;
        TxtTags.Text      = string.Join(", ", entry.Tags);
        ChkFavorite.IsChecked = entry.IsFavorite;
        ChkPrivate.IsChecked  = entry.IsPrivate;

        // Category combobox: find matching item by Tag
        foreach (ComboBoxItem item in CboCategory.Items)
        {
            if (item.Tag?.ToString() == entry.Category)
            {
                CboCategory.SelectedItem = item;
                break;
            }
        }

        // Decrypt and prefill password field
        if (entry.EncryptedValue.Length > 0)
        {
            try
            {
                var plain = EncryptionService.Shared.DecryptToString(entry.EncryptedValue);
                PwdValue.Password  = plain;
                TxtValuePlain.Text = plain;
            }
            catch
            {
                // Leave blank if decryption fails (wrong key / corrupted)
            }
        }
    }

    // ── Show / hide password toggle ───────────────────────────────────────────

    private void OnShowPasswordChanged(object sender, RoutedEventArgs e)
    {
        UpdateValueFieldVisibility();
    }

    private void OnCategoryChanged(object sender, SelectionChangedEventArgs e)
    {
        // Auto-show multi-line TextBox for non-password categories
        UpdateValueFieldVisibility();
    }

    /// Switches between PasswordBox (single-line) and TextBox (multi-line) based
    /// on category selection and "show password" toggle.
    private void UpdateValueFieldVisibility()
    {
        if (PwdValue == null || TxtValuePlain == null || CboCategory == null || ChkShow == null)
            return;

        var isPassword = (CboCategory.SelectedItem is ComboBoxItem sel)
                         && sel.Tag?.ToString() == "password";
        bool showPlain = !isPassword || ChkShow.IsChecked == true;

        if (showPlain)
        {
            if (PwdValue.Visibility == Visibility.Visible)
                TxtValuePlain.Text = PwdValue.Password;
            TxtValuePlain.Visibility = Visibility.Visible;
            PwdValue.Visibility      = Visibility.Collapsed;
        }
        else
        {
            if (TxtValuePlain.Visibility == Visibility.Visible)
                PwdValue.Password = TxtValuePlain.Text;
            PwdValue.Visibility      = Visibility.Visible;
            TxtValuePlain.Visibility = Visibility.Collapsed;
        }
    }

    // ── Save ──────────────────────────────────────────────────────────────────

    private void OnSaveClicked(object sender, RoutedEventArgs e)
    {
        // Validation
        var title = TxtTitle.Text.Trim();
        if (string.IsNullOrEmpty(title))
        {
            MessageBox.Show("标题不能为空。", "验证", MessageBoxButton.OK, MessageBoxImage.Warning);
            TxtTitle.Focus();
            return;
        }

        // Resolve plaintext value from whichever field is visible
        var plainValue = TxtValuePlain.Visibility == Visibility.Visible
            ? TxtValuePlain.Text
            : PwdValue.Password;

        // Resolve category tag from selected ComboBoxItem
        var category = "other";
        if (CboCategory.SelectedItem is ComboBoxItem selectedCat)
            category = selectedCat.Tag?.ToString() ?? "other";

        // Parse tags
        var tags = TxtTags.Text
            .Split(',', System.StringSplitOptions.RemoveEmptyEntries | System.StringSplitOptions.TrimEntries)
            .ToList();

        // Build or update entry
        var entry = _original is not null
            ? CloneForUpdate(_original)
            : new KeyValueEntry();

        entry.Title      = title;
        entry.Key        = TxtKey.Text.Trim();
        entry.Url        = TxtUrl.Text.Trim();
        entry.Group      = TxtGroup.Text.Trim();
        entry.Notes      = TxtNotes.Text.Trim();
        entry.Tags       = tags;
        entry.Category   = category;
        entry.IsFavorite = ChkFavorite.IsChecked == true;
        entry.IsPrivate  = ChkPrivate.IsChecked  == true;
        entry.UpdatedAt  = DateTime.UtcNow.ToString("O");

        // Encrypt value only if it changed (or is new)
        bool valueChanged = _original is null
            || !string.IsNullOrEmpty(plainValue);

        if (valueChanged && !string.IsNullOrEmpty(plainValue))
        {
            entry.EncryptedValue = EncryptionService.Shared.Encrypt(plainValue);
        }
        else if (_original is not null)
        {
            // Retain original encrypted data unchanged
            entry.EncryptedValue = _original.EncryptedValue;
        }

        StorageService.Shared.Upsert(entry);
        DialogResult = true;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Shallow clone preserving identity fields so Upsert updates the right row.
    private static KeyValueEntry CloneForUpdate(KeyValueEntry src) => new()
    {
        Id        = src.Id,
        CreatedAt = src.CreatedAt,
        UsageCount = src.UsageCount,
        LastUsedAt = src.LastUsedAt,
        Group     = src.Group
    };
}
