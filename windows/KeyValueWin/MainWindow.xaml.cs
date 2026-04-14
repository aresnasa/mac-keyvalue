using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using KeyValueWin.ViewModels;
using KeyValueWin.Views;

namespace KeyValueWin;

public partial class MainWindow : Window
{
    private MainViewModel VM => (MainViewModel)DataContext;

    public MainWindow()
    {
        DataContext = new MainViewModel();
        InitializeComponent();
        Loaded += (_, _) =>
        {
            VM.Initialize();
            RefreshGroupFilter();
            VM.PropertyChanged += OnVMPropertyChanged;
        };
    }

    private void OnVMPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainViewModel.AllGroups))
            RefreshGroupFilter();
    }

    private void RefreshGroupFilter()
    {
        var current = VM.SelectedGroup;
        CboGroupFilter.Items.Clear();
        CboGroupFilter.Items.Add(new ComboBoxItem { Content = "全部", Tag = "all" });
        foreach (var g in VM.AllGroups)
            CboGroupFilter.Items.Add(new ComboBoxItem { Content = $"📁 {g}", Tag = g });
        CboGroupFilter.SelectedValue = current;
        if (CboGroupFilter.SelectedItem is null)
            CboGroupFilter.SelectedIndex = 0;
    }

    private void OnNewEntryClicked(object sender, RoutedEventArgs e)
    {
        var win = new EntryEditWindow(null) { Owner = this };
        if (win.ShowDialog() == true)
        {
            VM.Initialize(); // reload
        }
    }

    private void OnEditEntryClicked(object sender, RoutedEventArgs e)
    {
        if (VM.SelectedEntry is null) return;
        var win = new EntryEditWindow(VM.SelectedEntry) { Owner = this };
        if (win.ShowDialog() == true)
        {
            VM.Initialize();
        }
    }

    private void OnUrlClicked(object sender, MouseButtonEventArgs e)
    {
        var url = VM.SelectedEntry?.Url;
        if (!string.IsNullOrWhiteSpace(url))
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch { /* ignore */ }
        }
    }
}
