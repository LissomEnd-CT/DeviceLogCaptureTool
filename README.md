# Device Log Capture

Tool portabile per esportare un file HAR della rete e un file LOG della console
da applicazioni Web/WebView su webOS, Tizen e Android.

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

Subito dopo il controllo dipendenze, digitare `G` per aprire la gestione SDK.
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
verificato. Pairing, Developer Mode, certificati e firma delle app restano
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

Al termine il tool aggiornato viene riaperto automaticamente. Se l'aggiornamento
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

### Android

- Android platform-tools installati;
- device autorizzato tramite ADB USB o rete;
- per una WebView, `WebView.setWebContentsDebuggingEnabled(true)` abilitato
  nell'applicazione.

Il tool rileva i socket `devtools_remote` e crea/rimuove il port-forward ADB.

### Tizen

- Developer Mode attivo;
- Tizen Studio/SDB installato;
- App ID/package noto;
- TV raggiungibile tramite SDB.

Il tool esegue `sdb shell 0 debug`, legge la porta inspector e gestisce il
port-forward.

### Endpoint diretto

Sono accettati link `http://...devtools...?ws=...`, URL `ws://...` ed endpoint
HTTP che espongono `/json/list`.

Gli inspector WebKit legacy sulla porta `9998`, come alcuni decoder Movistar,
accettano una sola sessione per avvio dell'app e possono chiuderla durante un
reload. Per questi endpoint il tool disattiva il reload automatico. Quando il
runtime non espone eventi `Network.*`, le URL delle XHR e gli errori HTTP
presenti nella console vengono convertiti in entry HAR contrassegnate con
`_fromConsole: true`; status, header e timing non riportati dal firmware restano
necessariamente incompleti.

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
|   |-- Apply-Update.ps1       Installazione aggiornamenti del tool
|   `-- Manage-Sdks.ps1        Installazione e aggiornamento SDK
`-- DeviceLogs/                File generati
```

Su vecchi runtime Chromium/WebKit può collegarsi un solo debugger alla volta:
chiudere Web Inspector, Chrome DevTools e `chrome://inspect` prima della cattura.
Il tool cattura contenuti CDP/WebView; non sostituisce `logcat` o `dlog` per
applicazioni completamente native.
