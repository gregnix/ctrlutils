# Provider-Schicht -- Stand

Das Provider-Interface abstrahiert ueber jeden Speicherort. Fuer Baum und
Liste ist alles nur ein Pfad mit Kindern -- ob lokal, in einer ZIP oder auf
einem Server, spielt keine Rolle. Dieses Dokument haelt fest, was existiert,
was wie geprueft ist und was die naechsten Adapter braeuchten.


## Was existiert

| Datei | Zeilen | Inhalt | Zustand |
|-------|--------|--------|---------|
| `tuprovider-0.1.tm` | 167 | Interface + Basisklasse + Local-Provider | fertig, getestet |
| `tuprovider/dav-0.1.tm` | 89 | WebDAV-Adapter ueber tudav | Adapter geprueft (tudav gestubbt) |
| `tuprovider/zip-0.1.tm` | 138 | ZIP-Provider (read-only) ueber tuzip | fertig, gegen echte ZIP getestet |
| `tkufiletree-prov.tm` | 283 | Konsument 1: Verzeichnisbaum | fertig, getestet |
| `tkufilelist-0.1.tm` | 175 | Konsument 2: Detail-Liste (Tablelist) | fertig, getestet |
| `tkupath-0.1.tm` | 95 | PathBar (Breadcrumb) -- die Inventar-Luecke | fertig, getestet |
| `tkutab-0.1.tm` | 130 | TabWidget -- die zweite Inventar-Luecke | fertig, getestet |
| `tkupreview-0.1.tm` | 120 | Vorschau-Widget (politikfrei: text/markdown/message) | fertig, getestet |
| `ctrlutils/cufileops-0.1.tm` | 307 | Controller: caps-gesteuerte Dateiops (war explorer/fileops) | fertig, getestet |
| `ctrlutils/cumonitor-0.1.tm` | 165 | Controller: provider-agnostischer Verzeichnis-Watcher | fertig, getestet |
| `ctrlutils/cufilter-0.1.tm` | 75 | Controller: Live-Filterfeld fuer die Dateiliste | fertig, getestet |
| `explorer.tcl` | 210 | Referenz-App: Tabs, Baum+Liste+Vorschau+Ops | fertig, getestet |

Ablage nach tm-Konvention:

    lib/tm/tclutils/tuprovider-0.1.tm
    lib/tm/tclutils/tuprovider/dav-0.1.tm
    lib/tm/tkutils/tkufiletree-*.tm     (gepatcht)


## Repo-Aufteilung (drei Schichten)

Nach genauer Pruefung der Abhaengigkeiten hat fileops KEINE App-Kopplung:
es bekommt Provider, Listen-Widget und Refresh-Callback per install-Parameter,
greift auf keine explorer-Globals zu, haengt nur am Provider-Interface und an
tkutils-Widgets. Es ist also wiederverwendbar -- aber KEIN Widget (kein Pfad,
kein cget/configure), sondern ein CONTROLLER, der Ereignisse auf Widgets mit
Provider-Operationen verdrahtet. Dafuer die dritte Schicht:

| Repo | Namespace | Praefix | Was | == MVC |
|------|-----------|---------|-----|--------|
| tclutils | tclutils:: | tu* | Logik, kein Tk | Model |
| tkutils | tkutils:: | tku* | Widgets (haben Pfad, cget/configure) | View |
| ctrlutils | ctrlutils:: | cu* | Controller/Glue (Verhalten auf Widgets) | Controller |

fileops wurde daher zu ctrlutils::cufileops (Modul cufileops-0.1.tm, Ablage
lib/tm/ctrlutils/). Verhalten unveraendert -- verifiziert: laedt, installiert,
caps-gesteuert, Copy/Paste mit Kollisionsschutz. Kuenftige Controller (D&D,
Undo/Redo, Suchleisten-Anbindung) gehoeren in dasselbe Repo. ERSTER solcher
Nachzuegler ist schon da: cumonitor, ein Verzeichnis-Watcher. Er POLLT ueber
die Provider-Schnittstelle (list) und difft einen Signatur-Schnappschuss
(name/type/size/mtime) -- provider-agnostisch, weil inotify nur lokal ginge,
nicht ueber ZIP/DAV. Erster Schnappschuss ist Baseline (feuert nicht),
Verzeichniswechsel re-baselined still; nach EIGENEN Ops ruft die App poke(),
damit sie ihre eigene Aenderung nicht zurueckgemeldet bekommt. In die App
verdrahtet: install je Tab, watch bei jedem goto, onchange frischt die Liste
auf, stop beim Tab-Schliessen. Verifiziert: externe Datei angelegt/geloescht
-> Liste frischt automatisch auf; ueber ZIP feuert nichts (kein Absturz).
Damit traegt ctrlutils drei Controller. Der dritte ist cufilter: ein
Live-Filterfeld, das ueber der Dateiliste tippend filtert. Dafuer bekam
tkufilelist eine -filter-Option + setFilter-Methode (Glob auf Dateinamen,
case-insensitiv; Ordner bleiben immer sichtbar, damit Navigation moeglich
bleibt). Bare Text wird als *text* umschlossen (Teilstring-Treffer), echtes
Glob (* ?) wird durchgereicht. Der Controller verdrahtet nur Entry->setFilter.
In der App: Filterfeld ueber der Liste, Filter wird bei Verzeichniswechsel
zurueckgesetzt (neuer Ordner erscheint vollstaendig). Verifiziert: "bericht"
und ".txt" filtern korrekt, clear/Navigation setzen zurueck.

  UMBRELLA + DOKU + TESTS: ctrlutils hat jetzt ein Umbrella-Paket
  (ctrlutils-0.1.tm, eine Ebene ueber den Modulen -- package require ctrlutils
  zieht alle drei), ein README (Schicht-Erklaerung + Controller-Doku) und
  tcltest-Tests im Hausstil (cumonitor.test 5, cufilter.test 4, cufileops.test
  3 -- ALLE GRUEN, GUI-Tests mit haveTk-Constraint). cufileops-Tests decken
  den Kern: caps-Verdrahtung, cross-provider Copy ZIP->lokal mit Inhalt,
  Kollisionsschutz. Ablage nach Konvention: lib/tm/ctrlutils-0.1.tm (Umbrella)
  + lib/tm/ctrlutils/cu*-0.1.tm (Module) + tests/ + all.tcl-Runner.


## Das Interface

Neun Operationen, bewusst klein -- genau die Schnittmenge, die `file` und
tudav beide koennen:

    list stat get put delete mkdir move copy    caps

Ein Verzeichniseintrag ist ein dict mit `name path type size mtime`
(name/path/type Pflicht, size/mtime best effort). Format stammt aus tudav.

Provider sind tcloo-Objekte (`tuprovider open <scheme> ?args?`), kein Global
-- so leben mehrere gleichzeitig (zwei Panes, lokal + ZIP nebeneinander).


## Faehigkeiten sind ehrlich

`caps` leitet sich daraus ab, welche Methoden ein Provider ueberschreibt --
ueber die TclOO-Aufloesungskette (`info object call`), robust auch bei
Vererbung. Ein Provider deklariert seine Faehigkeiten nicht doppelt.

| Provider | caps |
|----------|------|
| local | list stat get put delete mkdir move copy |
| dav | list stat get put delete |
| zip | list stat get |
| (Beispiel read-only) | list stat get |

Konvention (Weg C): read-only-Provider erben von `Base` und implementieren nur
was sie koennen. Eine Faehigkeit durch Ueberschreiben *wegzunehmen* ist
bewusst nicht vorgesehen -- read-only wird von Base aufgebaut, nicht von einem
schreibfaehigen Provider abgezogen.

Praktischer Nutzen: dav meldet ehrlich kein mkdir/move/copy (tudav hat kein
oeffentliches MKCOL/MOVE/COPY). Ein Copy-Dialog kann vorher fragen, statt zu
scheitern.


## Wie geprueft

- **Local**: gegen echte Dateien -- list/stat/get/put/delete, Eintragsdicts,
  alle acht caps. Verifiziert.
- **caps-Introspektion**: ueber vier Vererbungsfaelle, inklusive
  Provider-erbt-von-Provider (der Fall, an dem die erste, schludrige Fassung
  gescheitert waere). Verifiziert.
- **tkufiletree ueber Provider**: derselbe Baum laeuft ueber vier verschiedene
  Provider -- lokales Dateisystem, ein virtueller In-Memory-Provider,
  WebDAV und ZIP. Ordner zuerst, Dateien gefiltert, Unterordner-Expansion, in allen
  drei Faellen gleich. Rueckwaertskompatibel: ohne `-provider` verhaelt sich
  der Baum exakt wie zuvor.
- **DAV-Adapter**: Laden, Registrierung, caps-Teilmenge und Forwarding gegen
  einen tudav-Stub geprueft.
- **tkufilelist (zweiter Konsument)**: Detail-Liste ueber Tablelist, gefuellt
  aus einem Provider. Gegen local und ZIP getestet, mit menschenlesbarer
  Groesse und Verzeichnis-zuerst-Sortierung. Baum UND Liste koennen sich EINEN
  Provider teilen (verifiziert) -- die Grundlage der spaeteren App.
- **PathBar (tkupath)**: die einzige Widget-Luecke aus dem Inventar, jetzt
  gefuellt. Breadcrumb aus klickbaren Segmenten; ein Klick liefert den
  akkumulierten Pfad (Klick auf "greg" in /home/greg/docs -> /home/greg),
  nicht nur das Segment-Label. Provider-neutral. In die App verdrahtet: Baum,
  Liste UND Breadcrumb halten Verzeichnis, PathBar und Liste synchron ueber
  eine zentrale goto-Funktion.
- **Schreibseite (explorer::fileops)**: caps-gesteuertes Rechtsklick-Menue auf
  der Liste. New Folder / Rename / Delete erscheinen NUR, wenn der Provider die
  jeweilige Operation (mkdir/move/delete) kann. Verifiziert: local zeigt alle
  drei, ZIP zeigt nur "(read-only)" -- das UI bietet nie an, was fehlschlagen
  wuerde. Delete fragt nach, Rename/New Folder fragen nach dem Namen; nach jeder
  Aenderung wird die Liste neu geladen. App-Politik (kennt caps/Eintraege), also
  bei der App; die genutzten Widgets (Kontextmenue, Dialoge) sind tkutils.
  Bewaehrt endlich die SCHREIBHAELFTE des Provider-Interfaces (put/delete/mkdir).
  Copy/Paste kam dazu: ueber get+put auf App-Ebene statt der provider-internen
  copy-Operation -- dadurch CROSS-PROVIDER. Copy braucht Quelle-get, Paste
  braucht Ziel-put; ein modulweiter Clipboard merkt sich Quell-Provider+Pfad.
  Verifiziert: Datei aus einem ZIP ins lokale Verzeichnis herauskopiert; und
  ins ZIP hinein gibt es kein Paste (kein put) -- caps schuetzen konsistent.
  Rechtsklick waehlt zuerst die Zeile unter dem Cursor (sonst Gefahr, die
  falsche Datei zu treffen). Paste ueberschreibt NICHT mehr still: bei
  Namenskollision wird "name (copy).ext", "(copy 2)" usw. gewaehlt (via stat
  gegen den Zielprovider geprueft) -- desktop-ueblich, kein Datenverlust.
  Tastenkuerzel Delete/F2/Ctrl+C/Ctrl+V (caps- und auswahlgeschuetzt).
  Copy/Paste jetzt auch REKURSIV fuer Verzeichnisse: Copy eines Ordners
  braucht Quelle list+get, Paste braucht Ziel put+mkdir; _copyTree baut den
  Baum nach (Dateien via get+put, Unterordner per Rekursion). Cross-provider
  verifiziert -- ein ganzer Ordner aus einem ZIP ins lokale Verzeichnis
  herausgezogen, komplette Struktur mit Inhalten.
- **Vorschau (tkutils::tkupreview)**: dritte Spalte pro Tab, als
  POLITIKFREIES Bibliotheks-Widget -- konsistent mit Baum/Liste/PathBar/Tab.
  Es zeigt an, was man ihm gibt (text/markdown/message), kennt aber keine
  Endungen, Provider oder Eintraege. Die Zuordnung Endung -> Anzeigeart und das
  Lesen ueber $prov get liegen in der APP (onListSelect), nicht im Widget.
  Markdown ueber tkumdview (setMarkdown, Inhalt statt Pfad); da alles aus
  Provider-Bytes kommt, laeuft es ueber ZIP wie lokal (verifiziert). Bild/PDF
  Bild UND PDF kamen dazu: diese Viewer (tkuimage view/openFile,
  tkupdfinspect loadFile) nehmen einen Pfad, nicht Bytes -- die App schreibt
  die Provider-Bytes daher in eine Temp-Datei (_toTemp) und uebergibt den Pfad.
  Eine Temp pro Tab, die vorige wird bei jeder neuen Vorschau und beim
  Tab-Schliessen geloescht. Verifiziert: Bild UND PDF aus einem ZIP
  vorgeschaut (Bytes -> Temp -> Viewer), kind image/pdf, Aufraeumen greift.
  tkupreview hat jetzt text/markdown/html/json/xml/ini/csv/hex/image/photo/pdf/message -- alles
  politikfrei, die Endung->Typ-Zuordnung bleibt in der App.
  PDF wird GERENDERT (erste Seite als Bild) via tclpdfium (::pdfium::open/
  render/close -> Tk-photo), Anzeige ueber die neue photo-Methode. Faellt
  tclpdfium weg, gibt es den Struktur-Inspektor (tkupdfinspect) als Fallback.
  ECHT GETESTET mit den hochgeladenen pdfiumtcl-Binaries (Paket heisst
  "pdfiumtcl", NICHT tclpdfium): lokale PDF und PDF aus einem ZIP als 800px
  breite Seite gerendert (kind=photo), Bild mit Inhalt. Render-API bestaetigt:
  ::pdfium::open datei -> Handle; ::pdfium::render $doc 0 -width 800
  -imagename N -> Tk-photo-Name; 0-basierter Seitenindex; ::pdfium::close.
  Fallback auf tkupdfinspect wenn pdfiumtcl fehlt.
  CSV/TSV werden als TABELLE via tkucsv gezeigt (setData nimmt Text, kein
  Pfad -> direkt aus Provider-Bytes, wie Markdown). Verifiziert lokal und aus
  ZIP; .csv aus dem Text-Zweig in eigenen Zweig verschoben. TSV vs CSV:
  .csv wird komma-getrennt geparst, .tsv bekommt -delimiter \t (Tab) an die
  csv-Methode durchgereicht -- sonst haette eine TSV mangels Kommas als EINE
  Spalte ausgesehen (nachgewiesen: Komma-Default 1 Spalte, Tab 3 Spalten).
  Die csv-Methode nimmt jetzt optionale Parser-Args (politikfrei, das Widget
  wird nur ueber das Trennzeichen informiert).
  HTML wird GERENDERT via tcllitehtml (widget load nimmt HTML-Text, kein Pfad
  -> aus Provider-Bytes). Echt getestet mit den hochgeladenen tcllitehtml-
  Binaries (Paket "tcllitehtml", Widget ist im Kern ein Canvas, Methode load).
  Lokal und aus ZIP gerendert. HTML-Einbau nach dem tcllitehtml demo-browser:
  KEIN festes -width (Widget nimmt Pane-Breite, rendert bei <Configure> neu),
  Scrollbar, direktes load -- kein after/Configure-Gebastel. Vorschau-Pane
  breiter gemacht (Gewicht 1:2:5 + Breitenhinweise), sonst HTML/Tabellen zu
  schmal umbrochen. WICHTIG (aus Screenshot gelernt): litehtml legt das
  Dokument beim load mit seiner internen Breite (Default 800) aus und reflowt
  nur bei <Configure>. Wird das Widget in eine bereits ruhige Pane erzeugt,
  kommt kein Configure -> Text bricht bei 800 oder (bei schmal) ein Wort pro
  Zeile. Fix: nach load explizit tcllitehtml::_do_resize mit der echten
  winfo-Breite aufrufen -> reflow auf volle Pane-Breite sofort beim Klick.
  ENCODING (aus Diagnose-Doc): provider get liefert ROHE BYTES. Alle
  text-basierten Vorschauen dekodieren jetzt zentral in onListSelect als
  UTF-8 (mit BOM-Strip), sonst erscheinen Umlaute als Mojibake -- betraf
  HTML/Markdown/CSV/JSON/XML/INI/Text. Hex bleibt roh. Verifiziert: Umlaute
  korrekt. HTML-Fallback nicht mehr still: Grund steht im Header
  ("tcllitehtml not available" bzw. "render failed, showing source").

  ENGINE-GRENZE (Greg-Befund "manche HTML falsch"): tcllitehtml baut auf
  litehtml, das nur eine TEILMENGE von HTML/CSS kann. Empirisch geprueft
  (y-Positionen zweier divs): tables, lists, inline/block-CSS, style-block,
  FLEXBOX und FLOAT funktionieren; CSS GRID wird NICHT umgesetzt (divs landen
  untereinander statt nebeneinander); JavaScript wird gar nicht ausgefuehrt;
  Gradienten sind laut Demo "Phase 2". Das ist eine Grenze der Engine, KEIN
  Fehler der Vorschau-Verdrahtung -- CSS-lastige/moderne Seiten (grid, JS)
  rendern daher falsch. Nicht in tkupreview fixbar. Optionen: als bekannte
  Grenze dokumentieren, oder Seiten mit grid/JS erkennen und warnen.
  Weitere Viewer aus tkutils verdrahtet (statt selbst gebaut): tkujson
  (setJson), tkuxml (setXml), tkuini (loadText), tkuhexedit (setData) -- alle
  aus Provider-Bytes. Unbekannte/Binaerdateien fallen jetzt auf einen
  HEX-DUMP zurueck statt "no preview". Der Endung->Typ-switch wurde zu einer
  kompakten Tabelle (textKinds) refaktoriert; keine Regression.
  SQLITE: .db/.sqlite/.sqlite3 als Tabellen-Browser via tkusqlite (openFile
  nimmt Pfad -> ueber Temp-Datei wie PDF; nutzt externes sqlite3). Verifiziert
  lokal und aus ZIP: Tabellen erkannt, kind=sqlite, Klick zeigt Zeilen.
  BILD-FORMATE ueber Img (optionaler Upload imgtools): PNG/GIF/PPM/PGM sind
  nativ in Tk; JPEG/TIFF/BMP/ICO kommen dazu, WENN das jeweilige Img-Format-
  Paket laedt. Jedes Format wird EINZELN geladen (package require img::jpeg
  etc.), NICHT das Sammelpaket "Img" -- sonst reisst eine fehlende native Lib
  (libjpeg) alle Formate mit. Endung wird nur akzeptiert, wenn ihr Format
  wirklich geladen ist; sonst Hex-Fallback (kein Absturz). Verifiziert:
  mit Img BMP als Stellvertreter (kind=image), ohne Img faellt BMP auf Hex,
  PNG geht in beiden Faellen. JPEG JETZT ECHT VERIFIZIERT: Img 2.1.1 aus
  Quelle gebaut (Tarball-Upload) -- der Build kompiliert seine EIGENE libjpeg
  aus compat/libjpeg mit, die gebaute libtcl9jpegtcl*.so braucht daher KEINE
  System-libjpeg (ldd bestaetigt). Damit laden alle vier Formate (jpeg tiff
  bmp ico); echtes JPEG lokal UND aus ZIP als Bild vorgeschaut (kind=image).
  Vorschau-Code unveraendert -- es fehlte nur die funktionierende Bibliothek.
  Lehre: Img-Binaries gegen System-libjpeg62 scheitern, wenn die fehlt; der
  Selbstbau mit eingebetteter libjpeg ist der portable Weg (auch fuers
  Windows-Ziel, wo die DLLs libjpeg schon mitbringen).
  SVG wird GERENDERT via tcllunasvg (load data nimmt SVG-Text -> to_png ->
  als Bild angezeigt). Wie beim JPEG-Fall brauchten die vorgebauten Binaries
  eine native Lib (liblunasvg.so.3 + libplutovg.so.1), die fehlte; Loesung:
  lunasvg 3.5 aus github via cmake gebaut (plutovg-Submodul), dann laedt das
  vorgebaute tcllunasvg-Binary dagegen. Echt verifiziert: SVG lokal UND aus
  ZIP als Bild gerendert (kind=image). Ohne Renderer zeigt der SVG-Zweig die
  XML-Quelle (SVG ist XML). tksvg-Upload kam nicht an (leeres Zip), daher
  tcllunasvg genutzt.
- **TabWidget (tkutab)**: die zweite Widget-Luecke aus dem Inventar. Aufsatz
  auf ttk::notebook mit "+"-Knopf (neuer Tab) und Mittelklick-Schliessen, was
  dem nackten notebook fehlt. Callback-API (onnew/onclose/onselect). Isoliert
  getestet: add/current/setLabel/close/Events.
- **Explorer-App (Tabs)**: mehrere offene Verzeichnisse, jeder Tab mit
  EIGENEM Baum, Liste, Breadcrumb, cur. PROVIDER JETZT PRO TAB (frueher pro
  Session): der Provider liegt im Tab-State, nicht global. Damit koennen ein
  ZIP-Tab und ein Lokal-Tab GLEICHZEITIG offen sein, und cufileops kopiert
  zwischen ihnen (das Clipboard merkt sich den Quell-Provider). "+" oeffnet
  einen frischen lokalen Tab (home); ein "Open ZIP..."-Knopf oeffnet ein
  Archiv in einem neuen Tab. Verifiziert: zwei Tabs mit verschiedenen
  Providern gleichzeitig; CROSS-PROVIDER Copy/Paste im GUI -- Datei im ZIP-Tab
  kopiert, im lokalen Tab eingefuegt, landet mit korrektem Inhalt lokal.
  Regression geprueft: lokaler Start, Navigation, ZIP-Start, +-Tab -- alles ok.

  UNDO/REDO IN DER APP: cuundo ist jetzt im Explorer verdrahtet -- pro Tab ein
  cuundo::install (mit -list fuer Ctrl+Z/Ctrl+Y auf der Liste), und cufileops
  bekommt -onop [cuundo::record $f], sodass jede Dateioperation aufgezeichnet
  wird. Die Refresh-Kette cuundo -> cufileops::_refresh -> afterOps laedt die
  Liste nach einem Undo neu. Verifiziert im App-Kontext: mkdir -> Undo (Ordner
  weg, Liste aktualisiert) -> Redo (Ordner wieder da). Keine Regression beim
  App-Start; Ctrl+Z/Ctrl+Y auf der Liste gebunden.

  MENUELEISTE: der Explorer hat jetzt eine Menuleiste (File / Edit / View), die
  die Operationen auffindbar macht -- besonders Undo/Redo, die vorher nur ueber
  Tastatur erreichbar waren. Jeder Menuebefehl wirkt auf den AKTUELLEN Tab und
  holt dessen Auswahl aus der Tab-Liste, nutzt also dieselben cufileops/cuundo-
  Operationen wie Kontextmenue und Shortcuts. Undo/Redo-Eintraege werden beim
  Oeffnen des Edit-Menues per <<MenuSelect>> enabled/disabled (canUndo/canRedo).
  File: New Tab/Open ZIP/Close Tab/Quit; Edit: Undo/Redo/New Folder/Rename/
  Delete/Copy/Paste; View: Refresh. Verifiziert: Menue-Undo loescht den Ordner
  und aktiviert Redo; Menue-Op ohne Auswahl gibt "Select a file first." statt
  zu crashen.
- **Explorer-App**: die duenne Referenz-Anwendung. Baum links, Liste rechts,
  gekoppelt ueber EINEN geteilten Provider: Auswahl im Baum zeigt das
  Verzeichnis in der Liste, Doppelklick auf einen Ordner navigiert hinein.
  DIESELBE App laeuft ueber local UND ueber ZIP (nur `-zip archive.zip` statt
  eines Verzeichnisses) -- ohne eine Zeile Unterschied. Das ist der Beweis der
  Provider-Idee: fuer die App ist alles nur ein Verzeichnisbaum.
- **ZIP-Provider**: gegen eine ECHTE ZIP getestet (tuzip laeuft lokal, kein
  Stub noetig). Die Baumsynthese aus der flachen Eintragsliste -- Verzeichnisse
  sub/ und tief/ existieren nicht als ZIP-Eintraege, der Provider leitet sie
  aus den Pfaden ab -- ist ueber drei Ebenen verifiziert, ebenso get bei tief
  verschachtelten Dateien.

Grenze, ehrlich benannt: der DAV-Adapter wurde NICHT gegen einen echten
WebDAV-Server getestet (kein Netz zu einem solchen Host in der Umgebung). Der
HTTP-Verkehr ist tudavs Sache und dort erprobt; neu ist nur die Abbildung
href -> Eintrag und die caps-Teilmenge, und das ist verifiziert.


## Offen am DAV-Adapter (am lebenden Server zu bestaetigen)

- `stat` leitet dir/file heuristisch aus dem Trailing-Slash ab -- tudavs
  `getProperties` sagt den Typ nicht serveruebergreifend zuverlaessig.
- href -> name macht kein Prozent-Decoding (fuer den Baum unkritisch).


## Naechste Adapter

| Scheme | Basis | Aufwand | caps (erwartet) |
|--------|-------|---------|-----------------|
| zip | tuzip | FERTIG -- read-only, Baumsynthese aus flacher Liste | list stat get |
| ftp | neu | mittel | je nach Server |
| sftp | neu | mittel | list stat get put delete |

ZIP ist der naechste natuerliche Schritt: read-only ueber tuzip, erbt von
Base, implementiert nur list/stat/get -- caps meldet den Rest ehrlich als
fehlend. Danach haengen drei reale Backends am Interface und der Zuschnitt ist
breit genug gemessen.


## Bewusst nicht drin

- **Streaming**: get/put gehen ueber den ganzen Inhalt. Kanal-Varianten
  (`getchan`) erst, wenn ein Provider grosse Dateien braucht.
- **Verschieben ueber Provider-Grenzen** (lokal -> dav): kann das Interface
  nicht; `move` ist provider-intern. Aufgabe der App (get aus A, put in B,
  delete in A).
- **Pfad-Navigation ueber fremde Syntax**: `up`/`reveal` nutzen
  `file dirname`/`join` -- reine Textoperationen, fuer `/`-getrennte Pfade
  (local, dav) korrekt. Ein Provider mit exotischer Pfadsyntax braeuchte
  spaeter `parent`/`join`-Methoden.
- **Monitoring**: ERLEDIGT als ctrlutils::cumonitor (Polling ueber die
  Provider-Schnittstelle, provider-agnostisch) -- bewusst NICHT im Provider,
  da nicht jeder Speicherort Aenderungen pushen kann; der Poll ist der
  portable Boden.
