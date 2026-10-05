; Waiting Paws: Windows Firewall rules for the camera link, added only when installed for all users (the installer is
; elevated then). go2rtc talks to Xiaomi cameras over UDP (CS2) and the iPhone link listens on the home network; without
; these rules Windows asks on first use. Private networks only; the uninstaller removes them.
!macro customInstall
  ${if} $installMode == "all"
    ; A "Cancel" on an earlier firewall prompt leaves Block rules for these programs, and Block wins over Allow.
    nsExec::Exec 'netsh advfirewall firewall delete rule name=all program="$INSTDIR\resources\bin\go2rtc.exe"'
    nsExec::Exec 'netsh advfirewall firewall delete rule name=all program="$INSTDIR\${APP_EXECUTABLE_FILENAME}"'
    nsExec::Exec 'netsh advfirewall firewall delete rule name="Waiting Paws (camera)"'
    nsExec::Exec 'netsh advfirewall firewall delete rule name="Waiting Paws (iPhone link)"'
    nsExec::Exec 'netsh advfirewall firewall add rule name="Waiting Paws (camera)" dir=in action=allow program="$INSTDIR\resources\bin\go2rtc.exe" enable=yes profile=private description="go2rtc inside Waiting Paws: video from cameras on the home network"'
    nsExec::Exec 'netsh advfirewall firewall add rule name="Waiting Paws (iPhone link)" dir=in action=allow program="$INSTDIR\${APP_EXECUTABLE_FILENAME}" enable=yes profile=private description="Waiting Paws on an iPhone in the same Wi-Fi network"'
  ${endif}
!macroend

!macro customUnInstall
  nsExec::Exec 'netsh advfirewall firewall delete rule name="Waiting Paws (camera)"'
  nsExec::Exec 'netsh advfirewall firewall delete rule name="Waiting Paws (iPhone link)"'
!macroend
