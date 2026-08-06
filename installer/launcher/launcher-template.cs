// ======================================================================
//  Modele de lanceur CircusVOIP
// ======================================================================
//  Compile par installer\build-installer.ps1, une fois par lanceur, apres
//  substitution de __SCRIPTS__ et __TITLE__. Le compilateur utilise est
//  csc.exe du .NET Framework, livre avec Windows : aucun outil a installer,
//  ni sur la machine de build ni sur les runners GitHub.
//
//  Pourquoi un vrai .exe plutot qu'un raccourci vers pythonw.exe :
//    - un seul .exe demarre les deux serveurs d'un coup, ce qu'un raccourci
//      ne sait pas faire ;
//    - c'est un fichier qu'on peut copier, epingler, appeler depuis un
//      script ou une tache planifiee, sans dependre d'un .lnk ;
//    - une installation incomplete donne une boite de dialogue explicite au
//      lieu de l'echec muet d'un raccourci casse.
//
//  Ce que ca ne fait PAS : renommer le process. Le lanceur demarre
//  pythonw.exe et rend la main aussitot ; dans le gestionnaire de taches, les
//  deux serveurs restent deux pythonw.exe indiscernables.
//
//  Le chemin du runtime est resolu A L'EXECUTION, relativement a
//  l'emplacement du lanceur : l'installation reste deplacable, et rien
//  n'est code en dur au build.
//
//      <InstallDir>\CircusVOIP-Servers.exe   <- ce binaire
//      <InstallDir>\runtime\pythonw.exe
//      <InstallDir>\app\circusvoip_server.py
//
//  Les arguments recus sont transmis tels quels au(x) script(s), ce qui
//  permet par exemple : CircusVOIP-Positions.exe --headless
// ======================================================================

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class CircusVoipLauncher
{
    private static readonly string[] Scripts = { __SCRIPTS__ };
    private const string Title = "__TITLE__";

    private static void Fail(string message)
    {
        MessageBox.Show(message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    private static string Quote(string value)
    {
        return "\"" + value + "\"";
    }

    // --headless coupe l'interface tkinter du serveur : toute sa sortie part
    // alors sur stdout. Avec pythonw.exe elle serait jetee et le mode serait
    // muet, donc on bascule sur python.exe (console visible) dans ce cas.
    private static bool WantsConsole(string[] args)
    {
        foreach (string arg in args)
        {
            if (string.Equals(arg, "--headless", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        string root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string exe = WantsConsole(args) ? "python.exe" : "pythonw.exe";
        string python = Path.Combine(root, Path.Combine("runtime", exe));
        string appDir = Path.Combine(root, "app");

        if (!File.Exists(python))
        {
            Fail("Runtime Python introuvable :\n" + python +
                 "\n\nL'installation semble incomplete. Reinstallez CircusVOIP.");
            return 1;
        }

        // Arguments supplementaires transmis au script (ex. --headless).
        StringBuilder extra = new StringBuilder();
        foreach (string arg in args)
        {
            extra.Append(' ').Append(Quote(arg));
        }

        // Les scripts sont verifies AVANT d'en demarrer un seul : sur le
        // lanceur combine, mieux vaut ne rien lancer que laisser tourner le
        // serveur de positions seul en signalant l'absence de l'audio.
        foreach (string script in Scripts)
        {
            string full = Path.Combine(appDir, script);
            if (!File.Exists(full))
            {
                Fail("Script introuvable :\n" + full +
                     "\n\nL'installation semble incomplete. Reinstallez CircusVOIP.");
                return 1;
            }
        }

        foreach (string script in Scripts)
        {
            string full = Path.Combine(appDir, script);
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(python, Quote(full) + extra);
                psi.WorkingDirectory = appDir;
                // false : on veut que le processus herite de notre environnement
                // et reste independant, sans passer par le shell.
                psi.UseShellExecute = false;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                Fail("Echec du lancement de " + script + " :\n" + ex.Message);
                return 1;
            }
        }

        return 0;
    }
}
