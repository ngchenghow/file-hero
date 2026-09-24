; The SSD agent runs from resources\ and must not hold the files open during install or uninstall.
!macro customInit
  nsExec::Exec 'taskkill /F /IM file-hero-agent.exe'
!macroend
!macro customUnInit
  nsExec::Exec 'taskkill /F /IM file-hero-agent.exe'
!macroend
; Remove the per-user Explorer menu and sign-in autostart; an update re-registers them on first launch.
!macro customUnInstall
  ${ifNot} ${isUpdated}
    DeleteRegKey HKCU "Software\Classes\*\shell\FileHero.ShareToSSD"
    DeleteRegKey HKCU "Software\Classes\Directory\shell\FileHero.ShareToSSD"
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "FileHeroAgent"
  ${endIf}
!macroend
