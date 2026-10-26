/*
  Regole di base di MacCleaner (licenza MIT). Euristiche generiche sui
  comportamenti tipici di dropper, miner e script di phishing per macOS.
  Non sostituiscono un set di firme vero: aggiungi YARA-Forge o Elastic
  dalle Impostazioni.
*/

rule MacCleaner_Shell_Dropper
{
    meta:
        description = "Script che scarica ed esegue codice dalla rete"
        author = "MacCleaner"
        severity = "warning"
    strings:
        $curl = "curl" ascii
        $wget = "wget" ascii
        $pipe_sh = /\|\s*(sudo\s+)?(ba|z)?sh\b/ ascii
        $chmod = "chmod +x" ascii
        $tmp = /\/(tmp|private\/tmp|Users\/Shared|var\/tmp)\// ascii
    condition:
        filesize < 2MB and ($curl or $wget) and $pipe_sh and ($chmod or $tmp)
}

rule MacCleaner_Crypto_Miner
{
    meta:
        description = "Stringhe tipiche dei miner di criptovalute"
        author = "MacCleaner"
        severity = "danger"
    strings:
        $stratum = "stratum+tcp://" ascii nocase
        $stratum2 = "stratum+ssl://" ascii nocase
        $xmrig = "xmrig" ascii nocase
        $cryptonight = "cryptonight" ascii nocase
        $randomx = "randomx" ascii nocase
        $minerd = "minerd" ascii
        $pool = "pool.minexmr" ascii nocase
    condition:
        filesize < 50MB and 2 of them
}

rule MacCleaner_Reverse_Shell
{
    meta:
        description = "Apre una shell verso un computer remoto"
        author = "MacCleaner"
        severity = "danger"
    strings:
        $devtcp = "/dev/tcp/" ascii
        $nc_e = /\bnc\s+(-[a-z]*e|.*-e\s)/ ascii
        $bash_i = "bash -i >&" ascii
        $socket_py = "socket.socket(" ascii
        $dup2 = "os.dup2(" ascii
        $subprocess = "subprocess.call([\"/bin/sh\"" ascii
    condition:
        filesize < 2MB and ($devtcp or $nc_e or $bash_i or ($socket_py and $dup2) or $subprocess)
}

rule MacCleaner_Password_Prompt_Script
{
    meta:
        description = "Chiede la password con una finestra finta e la manda via rete (stealer)"
        author = "MacCleaner"
        severity = "danger"
    strings:
        $dialog = "display dialog" ascii nocase
        $hidden = "with hidden answer" ascii nocase
        $password = "password" ascii nocase
        $curl = "curl" ascii
        $osascript = "osascript" ascii
        $keychain = "login.keychain" ascii nocase
    condition:
        filesize < 5MB and $dialog and $hidden and $password and ($curl or $keychain or $osascript)
}

rule MacCleaner_Encoded_Osascript
{
    meta:
        description = "Esegue AppleScript o shell nascosti in base64"
        author = "MacCleaner"
        severity = "warning"
    strings:
        $osascript = "osascript" ascii
        $base64 = /base64\s+(-d|--decode|-D)/ ascii
        $eval = "eval" ascii
        $echo = /echo\s+["']?[A-Za-z0-9+\/=]{40,}/ ascii
    condition:
        filesize < 2MB and $base64 and ($osascript or $eval) and $echo
}

rule MacCleaner_Persistence_Writer
{
    meta:
        description = "Script che installa un elemento di avvio nascosto"
        author = "MacCleaner"
        severity = "warning"
    strings:
        $agents = "Library/LaunchAgents" ascii
        $daemons = "Library/LaunchDaemons" ascii
        $plist = "<key>RunAtLoad</key>" ascii
        $launchctl = "launchctl load" ascii
        $bootstrap = "launchctl bootstrap" ascii
        $hidden = /Library\/[^\s"']*\/\.[A-Za-z0-9_]+/ ascii
        $curl = "curl" ascii
    condition:
        filesize < 2MB and ($agents or $daemons) and ($plist or $launchctl or $bootstrap) and ($hidden or $curl)
}
