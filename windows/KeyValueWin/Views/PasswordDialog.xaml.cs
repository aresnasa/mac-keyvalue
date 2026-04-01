using System.Windows;
using System.Windows.Input;

namespace KeyValueWin.Views;

public partial class PasswordDialog : Window
{
    public string Password { get; private set; } = string.Empty;

    public PasswordDialog(string prompt)
    {
        InitializeComponent();
        PromptText.Text = prompt;
        Loaded += (_, _) => PwdBox.Focus();
    }

    private void OnOkClicked(object sender, RoutedEventArgs e)
    {
        Password = PwdBox.Password;
        DialogResult = true;
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) OnOkClicked(sender, new RoutedEventArgs());
    }
}
