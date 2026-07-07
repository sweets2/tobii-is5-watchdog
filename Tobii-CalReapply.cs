using System;
using System.IO;
using System.Threading;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Win32;

// Tobii-CalReapply: re-apply a tracker's STORED calibration to the live device
// WITHOUT recalibrating, via the safe engine-IPC path (Tobii.Interaction Host/Context).
//
// This fixes "Mode D": after a hibernate-resume the EyeX engine comes up in the
// Tracking state but with no calibration bound to the live device (0% CPU, IR LEDs
// dark). Pushing the stored calibration.setpm blob back through the engine binds it
// again -- the exact thing the calibration UI does, minus collecting new dots.
//
// It NEVER opens a raw Stream Engine gaze subscription (that resets this hardware);
// it talks to the engine as an ordinary interaction client.
//
// Usage:
//   Tobii-CalReapply.exe                 (auto-detect profile, tracker, .setpm; re-apply)
//   Tobii-CalReapply.exe setprofile <p>  (just re-select a profile)
//   Tobii-CalReapply.exe setcal <p> <trackerUri> <setpmPath> <numPoints> [hdrBytes]
//
// Exit codes: 0 = calibration data pushed (ResultCode Ok); 2 = error/aborted.
class CalReapply
{
    const string TobiiDir = @"C:\Program Files (x86)\Tobii\Tobii Configuration";
    const string RuntimeRoot = @"C:\ProgramData\Tobii\Tobii Platform Runtime";
    const int DefaultHeaderBytes = 16;   // .setpm = 16-byte header + raw EyeX calibration blob
    const int DefaultNumPoints = 9;
    static readonly HashSet<string> busy = new HashSet<string>();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetDllDirectory(string lpPathName);

    static Assembly Resolve(object s, ResolveEventArgs e)
    {
        string n = e.Name.Split(',')[0];
        if (busy.Contains(n)) return null;
        busy.Add(n);
        try { string p = Path.Combine(TobiiDir, n + ".dll"); return File.Exists(p) ? Assembly.LoadFrom(p) : null; }
        finally { busy.Remove(n); }
    }

    static volatile bool done = false;
    static string resultCode = "(none)";

    static int Main(string[] args)
    {
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        SetDllDirectory(TobiiDir);
        try { return Run(args); }
        catch (Exception ex) { Console.WriteLine("EXCEPTION: " + ex.GetType().Name + ": " + ex.Message); return 2; }
    }

    // --- registry helpers (this is an x86 process, so SOFTWARE\Tobii == WOW6432Node) ---
    static string RegStr(string subkey, string value)
    {
        using (RegistryKey k = Registry.LocalMachine.OpenSubKey(subkey))
            return k == null ? null : (k.GetValue(value) as string);
    }

    static string FindSetpm(string serial)
    {
        if (!Directory.Exists(RuntimeRoot)) return null;
        foreach (string modelDir in Directory.GetDirectories(RuntimeRoot))
        {
            string cand = Path.Combine(Path.Combine(modelDir, serial), "calibration.setpm");
            if (File.Exists(cand)) return cand;
        }
        // fallback: newest calibration.setpm anywhere under the runtime root
        string best = null; DateTime bestT = DateTime.MinValue;
        foreach (string f in Directory.GetFiles(RuntimeRoot, "calibration.setpm", SearchOption.AllDirectories))
        {
            DateTime t = File.GetLastWriteTimeUtc(f);
            if (t > bestT) { bestT = t; best = f; }
        }
        return best;
    }

    static int Run(string[] args)
    {
        string mode = args.Length > 0 ? args[0] : "auto";
        string profile, trackerUri = null, setpm = null;
        int numpts = DefaultNumPoints, hdr = DefaultHeaderBytes;

        if (mode == "auto" || mode == "setcal" && args.Length < 5)
        {
            // auto-detect everything from the registry + runtime store
            profile = RegStr(@"SOFTWARE\Tobii\EyeXConfig", "CurrentUserProfile");
            trackerUri = RegStr(@"SOFTWARE\Tobii\EyeXConfig", "DefaultEyeTracker");
            if (string.IsNullOrEmpty(profile) || string.IsNullOrEmpty(trackerUri))
            { Console.WriteLine("ABORT: could not read CurrentUserProfile / DefaultEyeTracker from registry."); return 2; }
            int slash = trackerUri.IndexOf("://");
            string serial = slash >= 0 ? trackerUri.Substring(slash + 3) : trackerUri;
            setpm = FindSetpm(serial);
            if (setpm == null) { Console.WriteLine("ABORT: no calibration.setpm found for serial " + serial + " (never calibrated?)."); return 2; }
            mode = "setcal";
            Console.WriteLine("auto: profile=" + profile + " tracker=" + trackerUri + " setpm=" + setpm);
        }
        else if (mode == "setprofile")
        {
            profile = args.Length > 1 ? args[1] : RegStr(@"SOFTWARE\Tobii\EyeXConfig", "CurrentUserProfile");
        }
        else // explicit setcal
        {
            profile = args[1]; trackerUri = args[2]; setpm = args[3];
            numpts = int.Parse(args[4]); hdr = args.Length > 5 ? int.Parse(args[5]) : DefaultHeaderBytes;
        }

        var host = new Tobii.Interaction.Host("CalReapply");
        host.EnableConnection();
        Thread.Sleep(4000);
        Tobii.Interaction.Model.IContext ctx = host.Context;
        if (ctx == null) { Console.WriteLine("ABORT: no engine context."); return 2; }

        Tobii.Interaction.Model.AsyncDataHandler h = delegate(Tobii.Interaction.Model.IAsyncData d)
        {
            try { Tobii.Interaction.Framework.ResultCode rc; if (d != null && d.TryGetResultCode(out rc)) resultCode = rc.ToString(); }
            catch (Exception ex) { resultCode = "rc-err:" + ex.Message; }
            done = true;
        };

        if (mode == "setcal")
        {
            byte[] raw = File.ReadAllBytes(setpm);
            if (raw.Length <= hdr) { Console.WriteLine("ABORT: .setpm smaller than header."); return 2; }
            byte[] blob = new byte[raw.Length - hdr];
            Array.Copy(raw, hdr, blob, 0, blob.Length);
            string ts = DateTime.UtcNow.ToString("o");
            Console.WriteLine("setcal: tracker=" + trackerUri + " numpts=" + numpts + " blobLen=" + blob.Length);
            ctx.SetProfileCalibrationDataAsync(profile, new Uri(trackerUri), ts, numpts, blob, h);
        }
        else
        {
            Console.WriteLine("setprofile: " + profile);
            ctx.SetCurrentProfileAsync(profile, h);
        }

        for (int i = 0; i < 100 && !done; i++) Thread.Sleep(100);
        Console.WriteLine("done=" + done + " resultCode=" + resultCode);
        Thread.Sleep(1500);
        host.DisableConnection();
        host.Dispose();
        return (done && resultCode == "Ok") ? 0 : 2;
    }
}
