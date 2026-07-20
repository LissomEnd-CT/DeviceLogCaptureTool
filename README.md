# Device Log Capture

Tool portabile per esportare un file HAR della rete e un file LOG della console
da applicazioni Web/WebView su TV, set-top box, webOS, Tizen, Android e runtime
Chromium/WebKit con inspector remoto.

Repository: <https://github.com/LissomEnd-CT/DeviceLogCaptureTool>

## Avvio

Fare doppio clic su `DeviceLogCapture.cmd` e seguire le richieste a schermo.
Per condividere il tool con un collega è sufficiente copiare l'intera cartella
`DeviceLogCaptureTool`.

Il tool chiede **tutte le opzioni prima di avviare l'app o il tunnel di debug**.
Quando la configurazione è terminata, collega immediatamente il recorder al primo
target disponibile (o al target che corrisponde al filtro inserito).

Durante la cattura usare normalmente il device. Per terminare, tornare nella
finestra e digitare `STOP`. I risultati vengono salvati in `DeviceLogs`:

- `.har`: richieste e risposte di rete, importabili nei DevTools;
- `.log`: console, warning, errori di rete ed eccezioni JavaScript.

## Controlli automatici

All'avvio viene mostrato lo stato di:

- Node.js 22 o successivo, obbligatorio;
- webOS CLI (`ares-inspect` e `ares-setup-device`) e numero di device configurati;
- Android Debug Bridge (`adb`) e device autorizzati/non autorizzati;
- Smart Development Bridge (`sdb`) e device Tizen collegati.

Una dipendenza `MANCANTE` non blocca le altre piattaforme. Node.js è l'unica
dipendenza comune e obbligatoria.

## Installazione e aggiornamento SDK

Subito dopo il controllo dipendenze, digitare `Y` per aprire la gestione SDK.
Dal menu è possibile installare o aggiornare una singola dipendenza oppure tutte:

- Node.js LTS 22 o successivo;
- webOS CLI/Ares;
- Android Platform Tools/ADB;
- Tizen SDB.

Le installazioni vengono salvate per il solo utente in
`%LOCALAPPDATA%\DeviceLogCaptureTool\Sdk` e caricate automaticamente a ogni
avvio. Non servono privilegi amministrativi e il tool non sovrascrive gli SDK
aziendali o le installazioni di Tizen Studio/Android Studio già presenti.

I pacchetti provengono esclusivamente dai canali ufficiali: Node.js viene anche
verificato con il manifest SHA-256 della release, Android Platform Tools arriva
da Google, SDB dal repository Tizen Studio e Ares dal pacchetto npm
`@webos-tools/cli`. Dopo ogni operazione il relativo eseguibile viene avviato e
verificato. Gli aggiornamenti vengono preparati separatamente e sostituiti solo
dopo la verifica; se questa fallisce viene ripristinata la versione precedente.
Pairing, Developer Mode, certificati e firma delle app restano
configurazioni specifiche del device e non possono essere automatizzate in modo
generico.

Riferimenti ufficiali: [Node.js](https://nodejs.org/en/download),
[Android Platform Tools](https://developer.android.com/tools/releases/platform-tools),
[webOS CLI](https://webostv.developer.lge.com/develop/tools/cli-installation) e
[repository Tizen Studio](https://download.tizen.org/sdk/tizenstudio/official/binary/).

## Aggiornamenti automatici

La versione installata è contenuta nel file `VERSION`. A ogni avvio il tool
interroga l'ultima GitHub Release e, se trova una versione superiore, chiede se
installarla subito o rimandare.

Il canale ufficiale è già configurato in `update-config.json`:

```json
{
  "githubRepository": "LissomEnd-CT/DeviceLogCaptureTool",
  "releaseAsset": "DeviceLogCaptureTool.zip"
}
```

Ogni release deve avere un tag semantico, per esempio `v1.2.0`. È consigliato
allegare un asset chiamato `DeviceLogCaptureTool.zip`; in sua assenza il tool usa
l'archivio sorgente della release. Lo ZIP deve contenere `DeviceLogCapture.cmd`.

Il workflow `.github/workflows/release.yml` crea automaticamente la release e lo
ZIP quando viene pubblicato un tag coerente con il file `VERSION`. Per pubblicare
una nuova versione:

1. aggiornare `VERSION` e le modifiche al codice;
2. eseguire i test e fare commit su `main`;
3. creare e pubblicare il tag corrispondente, per esempio `v1.2.0`.

Durante l'aggiornamento vengono preservati:

- `DeviceLogs`, inclusi tutti i HAR e LOG dell'utente;
- `update-config.json`, così la configurazione della repo non viene persa.

Quando GitHub fornisce il digest dell'asset, lo ZIP viene verificato con SHA-256
prima dell'estrazione. Il tool controlla inoltre versione, file obbligatori e
assenza di HAR/LOG nel pacchetto. L'installazione usa backup e rollback: una
copia incompleta non sostituisce la versione funzionante. Al termine il tool aggiornato viene riaperto
automaticamente. Se l'aggiornamento
fallisce, i dettagli vengono scritti in `DeviceLogs/update-error.log`.

La repo e le release ufficiali sono pubbliche: il controllo e il download degli
aggiornamenti non richiedono account GitHub, token o configurazione manuale.

## Requisiti per piattaforma

### webOS

- Developer Mode attivo sul TV;
- device già registrato con `ares-setup-device`;
- App ID noto;
- pacchetto npm `@webos-tools/cli` installato.

Il tool associa automaticamente l'IP al nome configurato e avvia `ares-inspect`.
Accetta sia i link DevTools moderni sia i frontend ospitati usati dai TV più
vecchi; attende la creazione del tunnel anche quando la CLI termina subito dopo
aver stampato il link.

### Android

- Android platform-tools installati;
- device autorizzato tramite ADB USB o rete;
- per una WebView, `WebView.setWebContentsDebuggingEnabled(true)` abilitato
  nell'applicazione.

Il tool attende i socket `devtools_remote`, gestisce più WebView/Chrome e
crea/rimuove il port-forward ADB. Le connessioni ADB di rete create dal tool
vengono chiuse al termine. Se il device è `unauthorized`, viene mostrata una
diagnosi specifica invece di un generico errore di connessione.

### Tizen

- Developer Mode attivo;
- Tizen Studio/SDB installato;
- App ID/package noto;
- TV raggiungibile tramite SDB.

Il tool esegue `sdb shell 0 debug`, legge la porta inspector e gestisce il
port-forward. La modalità predefinita è `Auto`: prova prima il comando standard
e, se non riceve una porta valida, riprova con
`sdb shell 0 debug APP_ID 10` per Tizen 4 e precedenti. È possibile forzare la
modalità standard o legacy prima dell'avvio dell'app. Le connessioni e i forward
SDB creati dal tool vengono rimossi al termine.

### Endpoint diretto

Sono accettati link `http://...devtools...?ws=...`, URL `ws://`/`wss://`, link
`inspector://...`, valori `IP:porta` ed endpoint HTTP/HTTPS che espongono `/json/list`
oppure `/json`. Se le route JSON non esistono, il tool legge anche la landing
page dell'inspector e ricava il WebSocket dai link HTML dei firmware legacy.
Gli indirizzi WebSocket
`0.0.0.0` restituiti da alcuni inspector vengono sostituiti automaticamente con
l'host del link HTTP.

### Profili device diretti

Quando viene inserito soltanto un IP si può scegliere un profilo, così le porte
più probabili vengono provate per prime:

| Famiglia | Porte | Comportamento |
| --- | ---: | --- |
| Chromium/WebView generico | 9222, 9223, 9229, 8080, 9999 | CDP standard |
| Samsung Tizen HbbTV 8+ | 7014, 7011 | Inspector HbbTV diretto |
| Hisense Vidaa | 9226 | Richiede DebugOn sul TV |
| TitanOS DevView | 7001 | Richiede DevView attivo |
| Sky Glass | 8090 | Hook compatibilità, reload automatico disattivato |
| Panasonic Viera | 52223 | WebKit diretto/legacy |
| Movistar BOB | 9224 | Accetta anche `inspector://` |
| Movistar/WebKit legacy | 9998 | Un solo debugger, niente reload automatico |

Il profilo `Auto` prova tutte le famiglie. Una porta non presente nel catalogo
resta utilizzabile inserendo direttamente `IP:porta`.

### Compatibilità Chromium/WebKit per anno

I domini CDP vengono abilitati indipendentemente e con timeout. La cattura non
fallisce più soltanto perché un vecchio firmware non implementa `Network`,
`Console`, `Runtime`, `Log` o `Page`. Il file LOG indica quali domini sono stati
attivati.

Quando `Network.*` non è disponibile, il recorder usa due fallback:

1. converte URL XHR ed errori HTTP già presenti nella console in entry HAR;
2. se `Runtime.evaluate` è disponibile, installa temporaneamente un hook XHR e
   `fetch` nella pagina ispezionata e ricostruisce metodo, URL, status e durata.

Le entry ricostruite sono marcate con `_fromConsole` o `_fromInjectedHook`.
Header, body e timing non esposti dal firmware non possono essere inventati e
restano incompleti. L'hook esiste solo nella sessione di debug, viene rimosso
alla chiusura normale della cattura e non modifica l'app installata.

## Protezione dei dati sensibili

Il progetto non deve contenere credenziali, token, indirizzi personali, URL
interni o identificativi aziendali. `tests/Sensitive-Data-Smoke.ps1` controlla
file correnti e cronologia Git; il workflow di release si interrompe prima di
creare lo ZIP se trova una corrispondenza. I valori eventualmente individuati
non vengono stampati nei log del test.

## Struttura della cartella

```text
DeviceLogCaptureTool/
|-- DeviceLogCapture.cmd       Avvio del tool
|-- DeviceLogCapture.ps1       Interfaccia, controlli SDK e port-forward
|-- README.md                  Questa guida
|-- VERSION                    Versione installata
|-- update-config.json         Repository e asset delle GitHub Releases
|-- lib/
|   |-- cdp-capture.js         Motore HAR/console
|   |-- device-profiles.json   Profili e porte dei device diretti
|   |-- Apply-Update.ps1       Installazione aggiornamenti del tool
|   `-- Manage-Sdks.ps1        Installazione e aggiornamento SDK
`-- DeviceLogs/                File generati
```

Su vecchi runtime Chromium/WebKit può collegarsi un solo debugger alla volta:
chiudere Web Inspector, Chrome DevTools e `chrome://inspect` prima della cattura.
Il tool cattura contenuti CDP/WebView; non sostituisce `logcat` o `dlog` per
applicazioni completamente native.
