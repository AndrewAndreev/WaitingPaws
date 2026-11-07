# Waiting Paws Privacy Policy

Effective November 6, 2026.

## In short
There is no Waiting Paws account, and no ads, analytics or tracking. The developer does not collect, receive or sell any of your data. Everything the app works with stays on your devices.

## What stays on your device
Settings, training schedules, training logs, video recordings and the app's diagnostic log are stored only on your device: in the app's storage on iPhone and Mac, in the Documents\Waiting Paws and %APPDATA%\Waiting Paws folders on Windows. Device backups (iCloud, Time Machine and others) may include them; iPhone backups leave out the diagnostic log. You can delete trainings and videos in History at any time.

## Deleting the app
**iPhone.** Deleting the app deletes its data, except two things in the iOS Keychain that iOS may keep: the password of your own go2rtc server and the keys that pair the iPhone with your computers. To remove them, clear that password and choose Forget for each computer in Settings before deleting the app.

**Mac.** Moving the app to the Trash leaves its data on the Mac. To remove it, also delete the folder ~/Library/Containers/su.comrade.waitingpaws. The password of your own go2rtc server, if you set one, is in Keychain Access under su.comrade.waitingpaws.

**Windows.** Uninstalling the app, or deleting its portable version, leaves your data. To remove it, delete the folders %APPDATA%\Waiting Paws (settings, the Xiaomi sign-in, the diagnostic log) and Documents\Waiting Paws (trainings and videos).

Videos saved to Photos, shared or exported stay where you put them.

## Camera and Xiaomi account
If you connect a Xiaomi (Mi Home) camera, the app's built-in go2rtc component sends your Xiaomi login and password directly from your device to Xiaomi's servers to sign in. The password is not saved. The access token Xiaomi returns is kept only on your device and is deleted when you choose "Sign Out of Xiaomi" in Settings or delete the app's data as described above. Video goes from the camera to your device over your local network. Your Xiaomi account is covered by Xiaomi's own privacy policy.

To show which settings your camera model supports (night mode and others), the app downloads public descriptions of camera models from miot-spec.org. Only the model identifier is requested.

The WebRTC player, the default with your own go2rtc server (on Windows it can also be chosen for the built-in one), contacts go2rtc's public STUN servers stun.cloudflare.com and stun.l.google.com to learn your network's public IP address; they see that address and nothing else. The MSE and HLS players, the default with the built-in go2rtc, don't; you can choose them under Player in Settings.

## iPhone and computer
When you link an iPhone with a Mac or Windows PC running Waiting Paws, the devices talk to each other directly over your local network, and nothing passes through the developer's servers. Pairing, the training and its commands are encrypted. Not encrypted: the devices' names and models, the camera's name and whether a training is running, which the devices announce on the network; and the camera's video, sound and controls (settings, turning), which are protected only by a password the app creates. Someone who can watch the traffic on your local network could see them and that password.

## Photos
With your permission, the app adds training videos to your Photos library. It can only add videos and cannot read your photos.

## Children
The app does not collect data from anyone, including children.

## Changes and contact
If this policy changes, the new version will be published with an app update. For questions, write to andrew@comrade.su or use the support link on the app's App Store page.
