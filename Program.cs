// Program.cs — Computer Maintenance Pro Enterprise Launcher v4.0
// Compiles with: csc.exe (C# 5, .NET Framework 4.0+)
// Purpose: UAC auto-elevation entry point -> launches PostInstallUI.ps1 as Administrator

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;

class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // Resolve the directory containing this exe (works even when called from a different CWD)
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        if (string.IsNullOrEmpty(exeDir))
            exeDir = AppDomain.CurrentDomain.BaseDirectory;

        string uiScript = Path.Combine(exeDir, "PostInstallUI.ps1");

        if (!File.Exists(uiScript))
        {
            MessageBox.Show(
                "PostInstallUI.ps1 bulunamadı:\n" + uiScript +
                "\n\nLütfen PostInstall klasörünün eksiksiz kopyalandığından emin olun.",
                "Başlatma Hatası",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 2;
        }

        // Check if already running as Administrator
        bool isAdmin;
        using (var id = WindowsIdentity.GetCurrent())
        {
            isAdmin = new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }

        if (!isAdmin)
        {
            // Request elevation via UAC
            try
            {
                string psArgs = string.Format(
                    "-NoProfile -Sta -ExecutionPolicy Bypass -File \"{0}\"",
                    uiScript);

                // Pass through flags if present
                bool resume = Array.IndexOf(args, "-Resume") >= 0 || Array.IndexOf(args, "/Resume") >= 0;
                bool auto   = Array.IndexOf(args, "-Auto") >= 0 || Array.IndexOf(args, "/Auto") >= 0 || Array.IndexOf(args, "-Silent") >= 0;
                if (resume) psArgs += " -Resume";
                if (auto)   psArgs += " -Auto";

                var psi = new ProcessStartInfo
                {
                    FileName        = "powershell.exe",
                    Arguments       = psArgs,
                    Verb            = "runas",          // UAC elevation request
                    UseShellExecute = true,
                    WorkingDirectory = exeDir
                };

                Process.Start(psi);
                return 0;
            }
            catch (System.ComponentModel.Win32Exception ex)
            {
                // User cancelled UAC dialog (Error 1223)
                if (ex.NativeErrorCode == 1223)
                {
                    MessageBox.Show(
                        "Yönetici onayı iptal edildi.\n\n" +
                        "Post-Installation Suite, doğru çalışabilmek için yönetici yetkisi gerektirir.\n" +
                        "Lütfen UAC isteğini onaylayın.",
                        "Yetki Gerekli",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                }
                else
                {
                    MessageBox.Show(
                        "Yükseltilmiş süreç başlatılamadı.\n\n" + ex.Message,
                        "Hata",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                }
                return 1;
            }
        }
        else
        {
            // Already admin — launch directly without re-elevation
            try
            {
                string psArgs = string.Format(
                    "-NoProfile -Sta -ExecutionPolicy Bypass -File \"{0}\"",
                    uiScript);

                bool resume = Array.IndexOf(args, "-Resume") >= 0 || Array.IndexOf(args, "/Resume") >= 0;
                bool auto   = Array.IndexOf(args, "-Auto") >= 0 || Array.IndexOf(args, "/Auto") >= 0 || Array.IndexOf(args, "-Silent") >= 0;
                if (resume) psArgs += " -Resume";
                if (auto)   psArgs += " -Auto";

                var psi = new ProcessStartInfo
                {
                    FileName         = "powershell.exe",
                    Arguments        = psArgs,
                    UseShellExecute  = false,
                    WorkingDirectory = exeDir
                };

                using (var proc = Process.Start(psi))
                {
                    proc.WaitForExit();
                    return proc.ExitCode;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "PowerShell başlatılamadı.\n\n" + ex.Message,
                    "Hata",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
