Set shell = CreateObject("WScript.Shell")

root = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
ps1 = root & "\src\Temenos.ps1"
runtime = shell.SpecialFolders("MyDocuments") & "\Temenos\runtime"

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & ps1 & Chr(34) & " -RuntimeRoot " & Chr(34) & runtime & Chr(34)
shell.Run cmd, 0, False
