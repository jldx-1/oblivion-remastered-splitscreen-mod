using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

internal static class Setup
{
    [STAThread]
    private static int Main()
    {
        string temp = Path.Combine(Path.GetTempPath(), "OblivionSplitScreen-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(temp);
            string archive = Path.Combine(temp, "installer.zip");
            using (Stream contents = Assembly.GetExecutingAssembly().GetManifestResourceStream("installer.zip"))
            using (FileStream output = File.Create(archive))
                contents.CopyTo(output);
            string extracted = Path.Combine(temp, "installer");
            ZipFile.ExtractToDirectory(archive, extracted);
            string powershell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            string script = Path.Combine(extracted, "Install.ps1");
            var launch = new ProcessStartInfo(powershell, "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"");
            launch.UseShellExecute = false;
            launch.CreateNoWindow = true;
            launch.RedirectStandardError = true;
            launch.RedirectStandardOutput = true;
            using (Process installer = Process.Start(launch))
            {
                var output = installer.StandardOutput.ReadToEndAsync();
                var errors = installer.StandardError.ReadToEndAsync();
                installer.WaitForExit();
                string message = installer.ExitCode == 0 ? output.Result.Trim() : errors.Result.Trim();
                MessageBox.Show(message, "Oblivion Remastered Local Split Screen",
                    MessageBoxButtons.OK, installer.ExitCode == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Error);
                return installer.ExitCode;
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Oblivion Remastered Local Split Screen", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try { if (Directory.Exists(temp)) Directory.Delete(temp, true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
