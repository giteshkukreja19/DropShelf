#!/usr/bin/env python3
"""Create one separate installer preview from the installed signed app. No release changes."""
import os, plistlib, shutil, subprocess, sys, tempfile
from pathlib import Path

def run(*args, **kw):
    return subprocess.run([str(a) for a in args],check=True,**kw)

def main():
    if sys.platform != 'darwin': raise RuntimeError('macOS required')
    app=Path(sys.argv[1]).resolve()
    with (app/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
    if info.get('CFBundleIdentifier')!='com.boski.dropshelf' or info.get('CFBundleShortVersionString')!='2.2.0': raise RuntimeError('Expected local 2.2.0 app')
    run('codesign','--verify','--deep','--strict',app)
    out=Path(sys.argv[2]).resolve()
    out.parent.mkdir(parents=True,exist_ok=True)
    vol='DropShelf 2.2.0'
    if (Path('/Volumes')/vol).exists(): raise RuntimeError('Eject the existing installer preview first.')
    with tempfile.TemporaryDirectory(prefix='installer-',dir=out.parent) as tmp:
        work=Path(tmp); rw=work/'layout.dmg'; candidate=work/'final.dmg'; stage=work/'contents'; stage.mkdir()
        run('ditto',app,stage/'DropShelf.app'); (stage/'Applications').symlink_to('/Applications')
        bg=stage/'.background'; bg.mkdir(); shutil.copy2(Path(__file__).with_name('installer-background.png'),bg/'installer.png')
        run('hdiutil','create','-volname',vol,'-srcfolder',stage,'-format','UDRW','-fs','HFS+','-size','128m',rw)
        data=plistlib.loads(run('hdiutil','attach','-nobrowse','-plist',rw,stdout=subprocess.PIPE).stdout)
        mounted=[e for e in data['system-entities'] if e.get('mount-point')]
        if len(mounted)!=1:
            for e in reversed(data['system-entities']):
                if e.get('dev-entry'): subprocess.run(['hdiutil','detach',e['dev-entry']],check=False)
            raise RuntimeError('Unexpected mount layout')
        dev=mounted[0]['dev-entry']; mount=Path(mounted[0]['mount-point'])
        try:
            if mount.name!=vol: raise RuntimeError('Unexpected volume name')
            run('osascript','-e','''tell application "Finder"
    tell disk "DropShelf 2.2.0"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 140, 840, 610}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 88
        set text size of opts to 13
        set background picture of opts to file ".background:installer.png"
        set position of item "DropShelf.app" of container window to {176, 215}
        set position of item "Applications" of container window to {464, 215}
        update without registering applications
        delay 2
        close container window
        open
        delay 2
        close container window
    end tell
end tell''')
            run('sync')
            if not (mount/'.DS_Store').is_file(): raise RuntimeError('Finder did not save its layout')
            run('codesign','--verify','--deep','--strict',mount/'DropShelf.app')
        finally:
            run('hdiutil','detach',dev)
        run('hdiutil','convert',rw,'-format','UDZO','-o',candidate)
        run('hdiutil','verify',candidate)
        os.replace(candidate,out)
    print('RELEASE INSTALLER:',out)

if __name__=='__main__':
    try: main()
    except Exception as e: sys.exit('STOPPED: '+str(e))
