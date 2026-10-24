param([string]$pipeName = "mpv-q-pipe")

$src = @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Threading;

public class MpvPipeRelay {
    public static void Run(string pipeName) {
        try {
            using (var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous)) {
                pipe.Connect(10000);
                var stdin = Console.OpenStandardInput();
                var stdout = Console.OpenStandardOutput();

                var t1 = new Thread(() => {
                    try {
                        byte[] buffer = new byte[8192];
                        int read;
                        while ((read = stdin.Read(buffer, 0, buffer.Length)) > 0) {
                            pipe.Write(buffer, 0, read);
                            pipe.Flush();
                        }
                    } catch {}
                    try { Thread.Sleep(300); } catch {}
                    Environment.Exit(0);
                });

                var t2 = new Thread(() => {
                    try {
                        byte[] buffer = new byte[8192];
                        int read;
                        while ((read = pipe.Read(buffer, 0, buffer.Length)) > 0) {
                            stdout.Write(buffer, 0, read);
                            stdout.Flush();
                        }
                    } catch {}
                    Environment.Exit(0);
                });

                t1.IsBackground = true;
                t2.IsBackground = true;
                t1.Start();
                t2.Start();

                Thread.Sleep(Timeout.Infinite);
            }
        } catch (Exception ex) {
            Console.Error.WriteLine("Error: " + ex.Message);
        }
    }
}
"@

Add-Type -TypeDefinition $src
[MpvPipeRelay]::Run($pipeName)
