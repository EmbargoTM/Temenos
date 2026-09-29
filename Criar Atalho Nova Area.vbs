Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
exe = fso.BuildPath(root, "Temenos.exe")
icon = fso.BuildPath(root, "assets\icons\NovaArea_ultra.ico")

desktop = shell.SpecialFolders("Desktop")
shortcutPath = fso.BuildPath(desktop, "+ Nova Área.lnk")

Set link = shell.CreateShortcut(shortcutPath)
link.TargetPath = exe
link.Arguments = "--new-area"
link.WorkingDirectory = root
link.Description = "Cria uma nova Área de Trabalho Virtual"
If fso.FileExists(icon) Then
    link.IconLocation = icon & ",0"
End If
link.Save

MsgBox "Atalho '+ Nova Área' criado/atualizado na Área de Trabalho.", 64, "Temenos"
