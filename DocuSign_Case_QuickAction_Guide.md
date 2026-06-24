# DocuSign Case Quick Action — Definitieve implementatiegids

Reproduceerbare opzet voor een Case-actie die een controlepagina toont (Account, Contact, controleur, plus een file browser met alle geschikte bestanden op de Case) en na bevestiging een DocuSign-envelope bouwt en verstuurt via Apex. De gebruiker selecteert met checkboxen welke bestanden meegaan in de envelope. Toegestane bestandstypen: **alle door DocuSign native ondersteunde formaten** (Word, Excel inclusief het oude `.xls`, PowerPoint, PDF, afbeeldingen, tekst, HTML, MSG, XPS, XML). De selectie moet altijd minstens één PDF bevatten omdat de handtekening-anchors alleen in de PDF-template staan. Sequential routing: controleur tekent eerst, klant daarna.

> **Status van de actie.** De knop heet `Verstuur via DocuSign (auto)` maar verstuurt **niet** automatisch — er zit een verplichte controle-stap (modal) tussen. Overweeg de label te wijzigen naar bijv. `Verstuur via DocuSign (Motrac)` om verwarring bij sales support te voorkomen. De standaard DocuSign-actie (`Verstuur via Docusign`) staat hier los van en blijft beschikbaar.

---

## 1. Architectuur

```
Case  →  Quick Action "Verstuur via DocuSign (auto)" (Custom Visualforce)
      →  Visualforce Page  DocusignCaseConfirm
      →  Apex controller    DocusignCaseConfirmController   (validatie + optimistic lock)
      →  Apex service       DocusignEnvelopeService          (bouwt + verstuurt envelope)
      →  DocuSign for Salesforce (dfsle)
```

| Component | API-naam | Type | Rol |
|-----------|----------|------|-----|
| Service | `DocusignEnvelopeService` | Apex class | Bouwt + verstuurt de envelope met de geselecteerde bestanden (`sendFilesFromCase`). Bevat inner `DocusignSendException`. |
| VF-controller | `DocusignCaseConfirmController` | Apex class | Laadt/valideert Case-data, toont de bestandslijst, valideert de selectie (optimistic lock), roept service aan. |
| Visualforce | `DocusignCaseConfirm` | VF page | Controle-UI met file browser (checkboxen) en double-submit guard. |
| Aura-controller | `DocusignCaseQuickActionController` | Apex class | **Optioneel/ongebruikt.** Alternatieve LWC/Aura-route naar dezelfde service. Niet gekoppeld aan de huidige knop. |

De Aura-controller hoeft niet gedeployed te worden als je alleen de Visualforce-route gebruikt. Hij is meegeleverd omdat hij in de org staat; laat 'm weg als je een schone deploy wilt.

---

## 2. Vereisten

- **DocuSign for Salesforce (dfsle)** geïnstalleerd én een DocuSign-account gekoppeld in de org. Zonder werkende dfsle-configuratie faalt `sendEnvelope` op runtime.
- **Toegestane bestandstypen**: alle door DocuSign native ondersteunde formaten — DOC/DOCX/DOTX, XLS/XLSX/CSV/XLSM, PPT/PPTX, PDF, RTF, TXT, HTM/HTML, MSG, WPD/WPS, XPS, XML, en de standaard afbeeldingen (PNG, JPG/JPEG, GIF, BMP, TIF/TIFF). Centraal vastgelegd in `DocusignEnvelopeService.ALLOWED_EXTENSIONS` (+ `ALLOWED_EXTENSIONS_LABEL`); beide controllers verwijzen direct naar deze constanten — pas ze op één plek aan en alle filters/labels lopen automatisch mee.
- **PDF verplicht in elke selectie**: de handtekening-anchors (`\i1\`, `\s2\`, `\n2\`) staan alleen in de Motrac-PDF-template. UI-, controller- en service-laag dwingen ieder af dat ten minste één geselecteerd bestand een PDF is, met een leesbare foutmelding vóór de dfsle-callout.
- Custom veld **`Ter_controle_van__c`** op Case, type **Lookup(User)**. Dit is de controleur/verkoper (signer 1). Bewust niet Case Owner — die kan een Queue zijn.
- Uitvoerende gebruikers hebben **toegang tot de Visualforce Page** (profiel of permission set) en de juiste **FLS** op de gebruikte velden (de SOQL draait `WITH USER_MODE`).
- **SortableJS** voor drag-and-drop in de modal. Default: CDN-referentie naar `cdn.jsdelivr.net/npm/sortablejs@1.15.2/Sortable.min.js`. Voor orgs met strikt CSP-beleid: download Sortable.min.js, upload als Static Resource met naam **`SortableJS`**, en vervang in de page de `<apex:includeScript value="https://cdn...">`-regel door `<apex:includeScript value="{!$Resource.SortableJS}"/>`. Als de bibliotheek niet laadt, blijft de modal werkend maar zonder drag-and-drop — de checkbox-volgorde uit het scherm wordt dan gebruikt als documentvolgorde.

---

## 3. Document-anchors

Minimaal één van de geselecteerde documenten moet de verplichte anchor-teksten bevatten. Anchors gelden **envelope-breed**: DocuSign zoekt de anchor-tekst in álle meegestuurde documenten. Verplichte tabs falen luid als hun anchor nergens voorkomt (envelope wordt dan niet verstuurd i.p.v. een handtekening stil te droppen).

| Anchor | Tab | Recipient | Verplicht | ignoreIfNotPresent |
|--------|-----|-----------|-----------|--------------------|
| `\i1\` | InitialHere | Controleur | Ja | `false` |
| `\s2\` | SignHere | Contact | Ja | `false` |
| `\n2\` | Text (naam) | Contact | Ja | `false` |
| `\ref2\` | Text (referentie) | Contact | Nee | `true` |
| `\cb_001\` … `\cb_200\` | Checkbox | Contact | Nee | `true` |

Elke checkbox krijgt een unieke naam (`motrac_cb_001` …) zodat DocuSign ze niet aan elkaar koppelt.

---

## 4. Reproductie — stap voor stap

> **Save-volgorde is dwingend.** Apex compileert use-sites mee. Sla altijd op in deze volgorde, anders krijg je `Variable does not exist` / `Method does not exist` op een afhankelijk component.

### Stap 1 — Apex classes (in deze volgorde)

Setup → Apex Classes → New, en plak per class de bijbehorende `.cls`:

1. `DocusignEnvelopeService` — de service. Geen afhankelijkheden behalve `dfsle`. **Eerst opslaan.**
2. `DocusignCaseConfirmController` — verwijst naar de service. Daarna opslaan.
3. `DocusignEnvelopeServiceTest` — testclass. Lees de `LET OP`-comment bovenin en pas org-specifieke velden/profielnaam aan.
4. *(optioneel)* `DocusignCaseQuickActionController` — alleen als je de Aura/LWC-route wilt.

> Geef een class **nooit** in-place een nieuwe naam. Apex kent geen rename; je maakt een nieuwe class en verwijdert de oude pas als niets er meer naar verwijst. Een mismatch hier was de oorzaak van de eerdere `Variable does not exist`-fouten.

### Stap 2 — Visualforce Page

Setup → Visualforce Pages → New:
- Label: `DocuSign Case Confirm`
- Name: `DocusignCaseConfirm`
- Plak `DocusignCaseConfirm.page`.
- Daarna: Security → zet de profielen aan die de actie mogen gebruiken.

### Stap 3 — Case Quick Action

Setup → Object Manager → **Case** → Buttons, Links, and Actions → **New Action**:

| Veld | Waarde |
|------|--------|
| Action Type | **Custom Visualforce** |
| Visualforce Page | `DocuSign Case Confirm [DocusignCaseConfirm]` |
| Height | `600` |
| Label | `Verstuur via DocuSign (auto)` (of een duidelijkere naam, zie noot bovenaan) |
| Name | `Verstuur_via_DocuSign_auto` |

> Maak een **Action**, geen **Button or Link**. Alleen Actions verschijnen in Dynamic Actions / Lightning Record Pages.

### Stap 4 — Knop op de Case tonen

Twee routes, **elkaars vervanging — niet beide**:

**Route A — Dynamic Actions (aanbevolen, dit is wat nu draait):**
Open een Case → tandwiel → **Edit Page** → selecteer het **Highlights Panel** → rechterpaneel **Add Action** → kies `Verstuur via DocuSign (auto)` → **Save** → **Activation** controleren.

**Route B — Page Layout (klassiek):**
Object Manager → Case → Page Layouts → juiste layout → sectie **Mobile & Lightning Actions** → sleep de actie naar **Salesforce Mobile and Lightning Experience Actions** → Save. *Let op: zodra je deze sectie aanpast, override je de standaard-actieset; sleep dan ook de te behouden acties (Edit etc.) mee.*

> Staat Dynamic Actions aan op de Lightning-pagina, dan negeert die de page-layout-lijst. Gebruik dan route A.

---

## 5. Testscenario (functioneel, in sandbox)

Maak/open een Case die volledig voldoet:

- Account gevuld
- Contact gevuld + e-mailadres
- `Ter_controle_van__c` = **actieve** User met e-mailadres
- Meerdere Salesforce Files van verschillende typen (bv. een PDF met de anchors uit §3, een DOCX, een XLSX, een legacy `.xls`, een PPTX en een afbeelding) plus één niet-ondersteund type (bv. `.exe` of `.zip`) om het filter te verifiëren

Stappen:
1. Klik `Verstuur via DocuSign (auto)`.
2. Modal laadt met de Case-gegevens ingevuld en een bestandslijst met checkboxen plus drag-handle (≡); alle door DocuSign ondersteunde formaten zijn zichtbaar, het niet-ondersteunde bestand ontbreekt, **geen** rode waarschuwing.
3. Sleep een DOCX naar boven de PDF, en sleep daarna de PDF terug naar de eerste positie — de greep moet zichtbaar reageren.
4. Klik **Versturen via DocuSign** zonder selectie → foutmelding "Selecteer minimaal één bestand".
5. Vink alléén niet-PDF-bestanden aan (bv. DOCX + XLSX) en klik versturen → foutmelding "Selecteer minimaal één PDF …".
6. Voeg de PDF toe aan de selectie en sleep hem als laatste → versturen → groene "Verzonden"-melding.
7. Controleer in DocuSign: alle geselecteerde documenten zitten in de envelope **in de gesleepte volgorde**, controleur = signer 1 (routing 1), contact = signer 2 (routing 2), tabs op de juiste anchors in de PDF.

Negatieve check (belangrijk na deploy): verstuur bewust een selectie **zonder** `\s2\` in enig document. Verwacht: een **luide fout**, geen lege/incomplete envelope.

---

## 6. Bekende beperkingen & aandachtspunten

| Onderwerp | Toelichting |
|-----------|-------------|
| **Anchor-parametervolgorde** | De 6e parameter van `dfsle.Tab.Anchor` is in deze code als `ignoreIfNotPresent` aangehouden. Verifieer dit één keer in jouw DFSLE-versie via de negatieve check in §5 (PDF zonder anchor → fout). |
| **`WITH USER_MODE` strictheid** | Kan op de `User`-query streng zijn als de uitvoerende gebruiker beperkte FLS heeft. Test met een echt sales-profiel, niet alleen als admin. Valt het tegen: per query terugvallen op `WITH SECURITY_ENFORCED`. |
| **Double-submit** | `actionStatus.onstart` disablet de knop + `if (sent) return;` in de controller. Dekt normale gevallen, is niet wiskundig waterdicht: twee snelle posts dragen dezelfde view state. Een server-side flag kan niet (DML vóór callout is verboden — `sendEnvelope` is een callout). Voor dit volume voldoende. |
| **Twee verzendroutes** | De standaard DocuSign-actie en deze custom actie staan naast elkaar. Bewust; communiceer richting sales support welke wanneer gebruikt wordt. |
| **Bestandsselectie** | De gebruiker kiest expliciet via checkboxen welke bestanden meegaan; de controller geeft exact die ContentVersion-ids door aan de service. Optimistic lock: bij versturen wordt per bestand gecontroleerd of het nog de laatste versie is, een toegestaan type heeft en nog aan de Case gekoppeld is — anders een luide fout. Selectie moet minstens één PDF bevatten; UI-, controller- en service-laag dwingen dit ieder af. |
| **Documentvolgorde** | Drag-and-drop in de modal (SortableJS) bepaalt de volgorde waarin DocuSign de documenten aan de klant toont. JS schrijft de volgorde in een verborgen `orderedIds`-veld; de controller respecteert die en de service hersorteert de `dfsle.Document`-lijst per `sourceId` voordat hij `withDocuments(...)` aanroept. Zonder JS valt het systeem terug op de checkbox-volgorde (nieuwste boven). |
| **Bestandstypen** | Alle door DocuSign native ondersteunde formaten (Word, Excel inclusief `.xls`, PowerPoint, PDF, afbeeldingen, tekst, HTML, MSG, XPS, XML). Eén `public static final` lijst in `DocusignEnvelopeService` (`ALLOWED_EXTENSIONS` + `ALLOWED_EXTENSIONS_LABEL`); beide controllers verwijzen daar direct naar. Wijzig op één plek; geen synchronisatie meer nodig. |
| **`System.debug`** | De service logt alleen het envelope-id op INFO. Geen namen/e-mails meer in logs. |

---

## 7. Deployment checklist (naar Production)

- [ ] `DocusignEnvelopeService`, `DocusignCaseConfirmController`, `DocusignEnvelopeServiceTest` (+ optioneel Aura-controller) in de deploy.
- [ ] `DocusignCaseConfirm` page + de Quick Action + de Lightning-pagina-wijziging.
- [ ] Geen referenties meer naar oude classnamen (`DocusignAcroformCheckboxTest`). Check via Developer Console → Search in Files.
- [ ] Testclass ≥ 75% coverage, assertions groen. Happy-path test draait door (zie `LET OP` als dfsle-config in test ontbreekt).
- [ ] DFSLE-account gekoppeld in de doel-org.
- [ ] PDF-template bevat de anchors uit §3.
- [ ] Sandbox-validatie gedaan: happy path **én** negatieve anchor-check.
- [ ] VF-page security toegekend aan de juiste profielen in Production.
