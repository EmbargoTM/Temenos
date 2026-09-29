Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(root, "src\NewDesktop.ps1")
icon = fso.BuildPath(root, "assets\icons\NovaArea_ultra.ico")

desktop = shell.SpecialFolders("Desktop")
shortcutPath = fso.BuildPath(desktop, "+ Nova Área.lnk")

Set link = shell.CreateShortcut(shortcutPath)
link.TargetPath = "powershell.exe"
link.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & ps1 & Chr(34)
link.WorkingDirectory = root
link.WindowStyle = 7
link.Description = "Cria uma nova Área de Trabalho Virtual"
If fso.FileExists(icon) Then
    link.IconLocation = icon & ",0"
End If
link.Save

MsgBox "Atalho '+ Nova Área' criado/atualizado na Área de Trabalho.", 64, "Temenos"
