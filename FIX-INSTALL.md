# Fixed DropShelf source

The build script now copies the generated SwiftPM resource bundle into the app before signing, checks signing, and removes the temporary DMG staging copy after packaging. The existing Sparkle feed and signing configuration are unchanged.

On macOS with full Xcode selected, copy the updated scripts/build-dmg.sh into your existing checkout to preserve your local Sparkle key. Run `bash scripts/build-dmg.sh` from that checkout. Open the newly generated DropShelf.dmg and replace the installed app, or copy dist/DropShelf.app to Applications after removing the old app. The older Droppy.dmg included in the original source archive is not rebuilt by this patch.

Validation: shell syntax checked on Linux; macOS compilation, signing and launch require testing on a Mac.
