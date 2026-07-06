' Launches the Tobii tray utility with no visible console window.
CreateObject("WScript.Shell").Run _
  "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\Scripts\Tobii-Tray.ps1""", 0, False
