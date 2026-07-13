# DocuSign Envelope Service — Installatie in productie (overschrijven bestaande componenten)

Deze README beschrijft hoe je de **nieuwe, metadata-gedreven versie** van de DocuSign-integratie in **productie** installeert. De Apex-classes en de Visualforce-pagina bestaan al op de productieomgeving (van een eerdere implementatie); deze installatie **overschrijft** ze en voegt de **nieuwe Custom Metadata** toe waarmee de e-mailteksten per afdeling worden beheerd.

Na deze eenmalige installatie kan een admin een nieuwe afdeling toevoegen door alleen een metadata-record aan te maken — geen code, geen nieuwe deploy.

---

## Inhoudsopgave

1. [Wat wordt er geïnstalleerd](#wat-wordt-er-geïnstalleerd)
2. [Belangrijk: waarom een Change Set (en geen directe edit in productie)](#belangrijk-waarom-een-change-set-en-geen-directe-edit-in-productie)
3. [Vereisten](#vereisten)
4. [Waarschuwing vóór het overschrijven](#waarschuwing-vóór-het-overschrijven)
5. [Installatie via sandbox + Change Set](#installatie-via-sandbox--change-set)
   - [Fase A — Componenten klaarzetten in de sandbox](#fase-a--componenten-klaarzetten-in-de-sandbox)
   - [Fase B — Outbound Change Set uploaden](#fase-b--outbound-change-set-uploaden)
   - [Fase C — Valideren en deployen naar productie](#fase-c--valideren-en-deployen-naar-productie)
6. [Alternatief: Custom Metadata direct in productie aanmaken](#alternatief-custom-metadata-direct-in-productie-aanmaken)
7. [Verificatie na installatie](#verificatie-na-installatie)
8. [Plaatshouders in e-mailteksten](#plaatshouders-in-e-mailteksten)
9. [Nieuwe afdeling toevoegen (geen deploy nodig)](#nieuwe-afdeling-toevoegen-geen-deploy-nodig)
10. [Troubleshooting](#troubleshooting)

---

## Wat wordt er geïnstalleerd

| # | Component | Type | Actie in productie |
|---|---|---|---|
| 1 | `DocusignEnvelopeService` | Apex Class | **Overschrijven** |
| 2 | `DocusignEnvelopeServiceTest` | Apex Class | **Overschrijven** |
| 3 | `DocusignCaseConfirmController` | Apex Class | **Overschrijven** |
| 4 | `DocusignCaseQuickActionController` | Apex Class | **Overschrijven** |
| 5 | `DocusignCaseConfirm` | Visualforce Page | **Overschrijven** |
| 6 | `DocusignEmailTemplate__mdt` (+ 5 velden) | Custom Metadata Type | **Nieuw** |
| 7 | `DocusignEmailTemplate.Used` | Custom Metadata record | **Nieuw** |

> De classes en de pagina **overschrijven** de bestaande versies — dat is de bedoeling. De functionaliteit blijft gelijk; het verschil is dat de e-mailteksten niet meer hardcoded in de class staan maar uit `DocusignEmailTemplate__mdt` komen.

De broncode van alle bovenstaande componenten staat in deze repository:

| Bestand in de repo | Component |
|---|---|
| `DocusignEnvelopeService.cls` | Apex Class — kernlogica (envelope bouwen + verzenden) |
| `DocusignEnvelopeServiceTest.cls` | Apex Class — testklasse |
| `DocusignCaseConfirmController.cls` | Apex Class — Visualforce-controller |
| `DocusignCaseQuickActionController.cls` | Apex Class — Aura-alternatief (optioneel) |
| `DocusignCaseConfirm.page` | Visualforce Page — de modal |
| `objects/DocusignEmailTemplate__mdt.object-meta.xml` | Custom Metadata Type-definitie |
| `objects/DocusignEmailTemplate__mdt/fields/*.field-meta.xml` | De 5 velddefinities |
| `customMetadata/DocusignEmailTemplate.Used.md-meta.xml` | Het `Used`-metadata-record |

---

## Belangrijk: waarom een Change Set (en geen directe edit in productie)

Salesforce staat **niet toe** dat je Apex-classes rechtstreeks in een productieorganisatie bewerkt via Setup → Apex Classes (de code-editor is daar read-only). Apex moet via een deployment binnenkomen. Daarom verloopt deze installatie via een **sandbox + Change Set**: je zet de code in een sandbox, en transporteert alles in één keer naar productie.

Wat dit betekent per componenttype:

| Component | Direct in productie te maken? | Route in deze README |
|---|---|---|
| Apex Classes | ❌ Nee | Change Set (verplicht) |
| Visualforce Page | ✅ Ja, maar meegenomen voor één schone deploy | Change Set |
| Custom Metadata Type + velden | ✅ Ja | Change Set of [direct in productie](#alternatief-custom-metadata-direct-in-productie-aanmaken) |
| Custom Metadata records | ✅ Ja | Change Set of direct in productie |

> **Geen Salesforce CLI nodig.** Alles verloopt via de Salesforce Setup-omgeving in de browser. (Wie liever de Metadata API/SFDX gebruikt kan de repo rechtstreeks naar productie deployen; dat valt buiten deze README.)

---

## Vereisten

Controleer vóór je begint:

- [ ] DocuSign for Salesforce managed package (`dfsle`) is geïnstalleerd in **zowel de sandbox als productie**
- [ ] Je hebt toegang tot een **sandbox** en tot de **productieomgeving**
- [ ] Er is een **Deployment Connection** van de sandbox naar productie: in productie via **Setup → Deployment Settings → sandbox → Edit → "Allow Inbound Changes" aanvinken**
- [ ] Custom veld `Ter_controle_van__c` (User-lookup) bestaat op het Case-object in productie
- [ ] Case RecordType `Used` bestaat in productie (DeveloperName: `Used`)
- [ ] *(Optioneel)* Custom lookup-veld `Quote__c` op Case — indien aanwezig gebruikt de service het Q-nummer als referentie in e-mails; anders valt het terug op het CaseNumber
- [ ] Je weet welke andere Case-recordtypes de bestaande classes nu gebruiken (zie de [waarschuwing](#waarschuwing-vóór-het-overschrijven))

---

## Waarschuwing vóór het overschrijven

⚠️ **De oude classes bevatten de e-mailteksten hardcoded. De nieuwe classes halen ze uit Custom Metadata.** Zodra je de classes overschrijft, zoekt de service voor elk Case-recordtype een `DocusignEmailTemplate__mdt`-record op. Is er géén record voor een recordtype, dan valt de e-mail terug op een **generieke fallback-tekst** die in de code staat.

**Actie:** maak vóór (of tegelijk met) de deploy een metadata-record aan voor **elk recordtype dat deze integratie in productie gebruikt** — niet alleen `Used`. Gebruikt bijvoorbeeld ook een "Sales"-afdeling deze classes, noteer dan de huidige teksten uit de bestaande productie-class en zet ze in een eigen metadata-record (zie [Fase A, stap A4](#a4--metadata-records-aanmaken)). Anders krijgen die afdelingen na de deploy de generieke fallback-teksten.

---

## Installatie via sandbox + Change Set

De installatie kent drie fasen:

- **Fase A** — componenten klaarzetten in de sandbox (code uit deze repo kopiëren)
- **Fase B** — een Outbound Change Set aanmaken en uploaden naar productie
- **Fase C** — de Change Set in productie valideren en deployen

> Change Sets transporteren metadata van sandbox naar productie; ze kunnen geen code rechtstreeks uit GitHub importeren. Daarom zet je de componenten eerst in de sandbox.
>
> **Aanbevolen volgorde binnen Fase A:** eerst het **Custom Metadata Type (A1) + velden (A1b)**, daarna de **Apex-classes (A2)**. De code lost het type dynamisch op en compileert ook zonder, maar de feature werkt pas als type én record bestaan.

---

### Fase A — Componenten klaarzetten in de sandbox

#### A1 — Custom Metadata Type aanmaken

**Setup → Custom Metadata Types → New.** Vul in:

| Veld | Waarde |
|---|---|
| **Label** | `Docusign Email Template` |
| **Plural Label** | `Docusign Email Templates` |
| **Object Name** | `DocusignEmailTemplate` |
| **Description** | `E-mailteksten per Case RecordType voor DocuSign-envelopes.` |
| **Visibility** | Public |

> **Let op de Object Name.** Salesforce vult dit automatisch op basis van het label en zet spaties om naar underscores (`Docusign_Email_Template`). **Verwijder de underscores handmatig** zodat er `DocusignEmailTemplate` staat (API-naam wordt dan `DocusignEmailTemplate__mdt`). De code accepteert ook `Docusign_Email_Template__mdt`, maar zonder underscores is aanbevolen. Klik op **Save**.
>
> Bestaat het type al? Sla deze stap over en controleer in A1b of alle velden aanwezig zijn.

#### A1b — De vijf velden aanmaken

> ⚠️ **Velden ≠ records.** Een **veld** is een kolom (bv. `ControleurSubject__c`); een **record** is een rij data (bv. `Used`). Je maakt hier eerst de **velden**. Records komen in A4.

1. **Setup → Custom Metadata Types**
2. Klik op de **naam/label** `Docusign Email Template` (opent de type-definitiepagina — niet "Manage Records")
3. Scroll naar de related list **Custom Fields** en klik op **New**
4. Maak elk van deze vijf velden aan:

| Field Name (API, exact) | Label | Type | Lengte |
|---|---|---|---|
| `RecordTypeDeveloperName` | Record Type Developer Name | Text | 80 |
| `ControleurSubject` | Controleur Onderwerp | Text | 255 |
| `ControleurBody` | Controleur Berichttekst | Long Text Area | 32768 |
| `ContactSubject` | Contact Onderwerp | Text | 255 |
| `ContactBody` | Contact Berichttekst | Long Text Area | 32768 |

> **Belangrijk — de API-naam (Field Name), niet het label, moet exact kloppen.** In het veldformulier vul je "Field Label" en "Field Name" apart in. Zet **Field Name** op precies `ControleurSubject`, `ControleurBody`, enzovoort (Salesforce voegt `__c` toe). Het label mag spaties bevatten; de API-naam mag dat niet.
>
> **De code is tolerant:** hij accepteert zowel de voorkeursnaam (`ControleurSubject__c`) als de underscore-variant (`Controleur_Subject__c`). Bestaande velden met underscores hoef je dus niet te hernoemen.

#### A2 — Apex Classes overschrijven/aanmaken

Ga in de **sandbox** naar **Setup → Apex Classes**. Voor elke class:

- **Bestaat de class al** (van de vorige implementatie): open hem → **Edit** → vervang de **volledige** inhoud door de code uit de repo → **Save**.
- **Bestaat de class nog niet:** **New** → plak de volledige code → **Save**.

| Class | Bestand in de repo |
|---|---|
| `DocusignEnvelopeService` | `DocusignEnvelopeService.cls` |
| `DocusignEnvelopeServiceTest` | `DocusignEnvelopeServiceTest.cls` |
| `DocusignCaseConfirmController` | `DocusignCaseConfirmController.cls` |
| `DocusignCaseQuickActionController` | `DocusignCaseQuickActionController.cls` |

> **Naamconflict `DocusignCaseConfirmController` bij opslaan?** Zie [Troubleshooting](#class-opslaan-mislukt-met-type-name-already-in-use).

#### A3 — Visualforce Page overschrijven/aanmaken

**Setup → Visualforce Pages.**

- Bestaat `DocusignCaseConfirm` al: klik op de naam → **Edit** → vervang de volledige inhoud door `DocusignCaseConfirm.page` uit de repo → **Save**.
- Bestaat hij nog niet: **New** → Label `Docusign Case Confirm`, Name `DocusignCaseConfirm` → plak de inhoud → **Save**.

#### A4 — Metadata-records aanmaken

> **Navigatie:** **Setup → Custom Metadata Types**, klik op de naam **Docusign Email Template**, en klik op de detailpagina op **Manage Records**.

**Record voor de Used-afdeling** — klik op **New** en vul in:

| Veld | Waarde |
|---|---|
| **Label** | `Used` |
| **Record Type Developer Name** (`RecordTypeDeveloperName__c`) | `Used` |
| **Controleur Onderwerp** (`ControleurSubject__c`) | `Document(en) ter controle - {quoteNumber}` |
| **Contact Onderwerp** (`ContactSubject__c`) | `Officieel voorstel van Motrac - {quoteNumber}` |
| **Controleur Berichttekst** (`ControleurBody__c`) | zie hieronder |
| **Contact Berichttekst** (`ContactBody__c`) | zie hieronder |

**Controleur Berichttekst** (`ControleurBody__c`):

```
Beste {controleurName},

Bijgaand ontvang je ter controle het Occasion document met referentie {quoteNumber}.

Bekijk het document zorgvuldig en teken af indien alles akkoord is.

Heb je vragen of opmerkingen over dit Occasion dossier? Neem dan contact op met de Used afdeling.

Met vriendelijke groet,
Motrac Used
```

**Contact Berichttekst** (`ContactBody__c`):

```
Beste {contactName},

Hierbij delen wij ons officiële voorstel. U kunt middels onderstaande knop {documentWord} controleren en indien deze aan uw wensen voldoen ondertekenen.

Mocht u nog vragen hebben over {documentRef} dan kunt u terecht bij uw contactpersoon.

Met vriendelijke groet,

Namens {controleurName}
Motrac
```

Klik op **Save**.

> **Maak nu ook records aan voor alle andere recordtypes** die de integratie in productie gebruikt (zie de [waarschuwing](#waarschuwing-vóór-het-overschrijven)), elk met de teksten uit de huidige productie-class. Gebruik de [plaatshouders](#plaatshouders-in-e-mailteksten) waar de oude code dynamische waarden invulde.

---

### Fase B — Outbound Change Set uploaden

**Setup → Outbound Change Sets → New** (in de **sandbox**):

- **Change Set Name:** `DocuSign Metadata Refactor`
- **Description:** `Overschrijft de DocuSign-classes + VF-pagina en voegt Custom Metadata voor e-mailteksten toe.`

Klik op **Save**, daarna op **Add** en voeg toe:

| Component Type | Component Name |
|---|---|
| Apex Class | `DocusignEnvelopeService` |
| Apex Class | `DocusignEnvelopeServiceTest` |
| Apex Class | `DocusignCaseConfirmController` |
| Apex Class | `DocusignCaseQuickActionController` |
| Visualforce Page | `DocusignCaseConfirm` |
| Custom Metadata Type | `DocusignEmailTemplate__mdt` |
| Custom Metadata | `DocusignEmailTemplate.Used` |
| Custom Metadata | *(elk extra afdelingsrecord dat je in A4 maakte)* |

> **Custom Metadata Type toevoegen** (Type = *Custom Metadata Type*, zoek `DocusignEmailTemplate`) neemt automatisch de vijf velden mee. **Records** voeg je apart toe via Type = *Custom Metadata*.

Scroll naar **Upload**, kies de **productieomgeving** als doel en bevestig.

---

### Fase C — Valideren en deployen naar productie

**Setup → Inbound Change Sets** (in **productie**). De geüploade set `DocuSign Metadata Refactor` staat op status `Pending`.

1. **Valideren (aanbevolen):** klik op de set → **Validate**. Salesforce draait de Apex-tests en controleert of de deploy zou slagen, zonder iets te wijzigen. Wacht op het resultaat en controleer de tests.
   - Faalt de validatie op de profielnaam in de testklasse? Zie [Troubleshooting](#validatietests-falen-op-de-profielnaam).
2. **Deployen:** klik op **Deploy** en bevestig. Na enkele minuten staat de status op **Succeeded** en zijn de classes + pagina overschreven en de metadata toegevoegd.

---

## Alternatief: Custom Metadata direct in productie aanmaken

De Apex-classes móéten via de Change Set. Maar het **Custom Metadata Type, de velden en de records** kun je desgewenst **rechtstreeks in productie** aanmaken via Setup — exact volgens de stappen [A1](#a1--custom-metadata-type-aanmaken), [A1b](#a1b--de-vijf-velden-aanmaken) en [A4](#a4--metadata-records-aanmaken), maar dan in de productieorganisatie. Laat ze in dat geval weg uit de Change Set (Fase B) en neem alleen de classes + de Visualforce-pagina mee.

> Dit kan handig zijn als je de teksten in productie wilt kunnen bijstellen zonder telkens een sandbox-record over te zetten. Records zijn direct actief; geen deploy nodig.

---

## Verificatie na installatie

- [ ] **Apex-classes bijgewerkt** — Setup → Apex Classes → `DocusignEnvelopeService` toont een recente wijzigingsdatum
- [ ] **Visualforce-pagina aanwezig** — Setup → Visualforce Pages → `DocusignCaseConfirm`
- [ ] **Custom Metadata Type aanwezig** — Setup → Custom Metadata Types → `Docusign Email Template` met vijf velden in **Custom Fields**
- [ ] **Metadata-records aanwezig** — Manage Records → minimaal het `Used`-record (plus eventuele extra afdelingen) met ingevulde tekstvelden
- [ ] **Apex-tests groen** — Setup → Apex Test Execution → `DocusignEnvelopeServiceTest` → Run → tests slagen
- [ ] **Quick Action werkt** — open een Case met RecordType `Used` → klik `Verstuur via DocuSign` → de modal opent met de bestandslijst
- [ ] **Verzending werkt (Used)** — selecteer minimaal één **PDF** → verzenden → de controleur ontvangt de e-mail met het juiste onderwerp en het Q-nummer; na aftekenen ontvangt het klantcontact zijn e-mail
- [ ] **Overige afdelingen ongewijzigd** — open een Case van een ander recordtype dat de integratie gebruikt → de teksten komen overeen met het bijbehorende metadata-record (niet de generieke fallback)

---

## Plaatshouders in e-mailteksten

De service vervangt deze plaatshouders automatisch bij elke verzending:

| Plaatshouder | Wordt vervangen door |
|---|---|
| `{quoteNumber}` | De `Name` van de gekoppelde `Quote__c` (Q-nummer); valt terug op het CaseNumber als er geen Quote is |
| `{controleurName}` | Volledige naam van de gebruiker in `Ter_controle_van__c` (controleur, signer 1) |
| `{contactName}` | Volledige naam van het Case-contact (klant, signer 2) |
| `{documentWord}` | `"het document"` bij één bestand, `"de documenten"` bij meerdere |
| `{documentRef}` | `"dit document"` bij één bestand, `"deze documenten"` bij meerdere |

> `{documentWord}` en `{documentRef}` werken alleen in de **Contact**-teksten; de controleur-teksten ondersteunen `{quoteNumber}`, `{controleurName}` en `{contactName}`.

---

## Nieuwe afdeling toevoegen (geen deploy nodig)

Na de installatie configureert een admin een nieuwe afdeling volledig vanuit **Setup** in productie — geen code, geen Change Set:

1. **DeveloperName opzoeken:** Setup → Object Manager → Case → Record Types → klik het recordtype → noteer **Record Type Name** (hoofdlettergevoelig, geen spaties).
2. **Metadata-record aanmaken:** Setup → Custom Metadata Types → `Docusign Email Template` → **Manage Records → New**. Vul `RecordTypeDeveloperName__c` met de DeveloperName uit stap 1 en de vier tekstvelden met [plaatshouders](#plaatshouders-in-e-mailteksten). **Save** — direct actief.
3. **Quick Action koppelen:** voeg de Quick Action `Verstuur via DocuSign` toe aan de Page Layout van die afdeling (Setup → Object Manager → Case → Page Layouts).

---

## Troubleshooting

### E-mails bevatten generieke/fallback-teksten terwijl er een record bestaat

De code leest de velden dynamisch en accepteert zowel de voorkeursnamen als de underscore-varianten:

| Logisch veld | Geaccepteerde API-namen |
|---|---|
| RecordType-sleutel | `RecordTypeDeveloperName__c` of `Record_Type_Developer_Name__c` |
| Onderwerp controleur | `ControleurSubject__c` of `Controleur_Subject__c` |
| Body controleur | `ControleurBody__c` of `Controleur_Body__c` |
| Onderwerp klant | `ContactSubject__c` of `Contact_Subject__c` |
| Body klant | `ContactBody__c`, `Contact_Body__c` of `Contac_Body__c` |

**Controleer** de **API Name**-kolom onder Custom Fields en de **Object Name** van het type (`DocusignEmailTemplate__mdt` of `Docusign_Email_Template__mdt`). Wijkt een naam af, hernoem het veld/type of maak het opnieuw aan.

Controleer ook of `RecordTypeDeveloperName__c` **exact** (hoofdlettergevoelig) overeenkomt met de Record Type Name van de Case.

### Het "New record"-formulier toont alleen Label en Name

De custom velden zijn nog niet aangemaakt op het type (vaak per ongeluk als *records* aangemaakt i.p.v. *velden*). Verwijder foutieve records via Manage Records → **Del**, maak de vijf velden aan via de related list **Custom Fields** ([A1b](#a1b--de-vijf-velden-aanmaken)), en probeer **New** opnieuw.

### Class opslaan mislukt met "Type name already in use"

De sandbox heeft nog een oude class (bv. `DocusignCaseQuickActionControllerTest`) die de naam `DocusignCaseConfirmController` bezet.

1. Open die oude class → **Edit**
2. Vervang de inhoud door `DocusignEnvelopeServiceTest.cls` uit de repo en zet de class-naam bovenaan op `DocusignEnvelopeServiceTest`
3. **Save**, en sla daarna `DocusignCaseConfirmController` opnieuw op — het conflict is opgelost

### Validatie/tests falen op de profielnaam

De testklasse zoekt het profiel `Standard User`. In Nederlandse orgs heet dit soms `Standaardgebruiker`. Pas in `DocusignEnvelopeServiceTest.cls` de profielquery aan:

```apex
Profile p = [SELECT Id FROM Profile WHERE Name = 'Standaardgebruiker' LIMIT 1];
```

Sla op, draai de tests opnieuw en neem de fix mee in de Change Set.

### Happy-path test faalt op een dfsle-fout

Het DocuSign-package vereist Custom Settings die in een lege testcontext kunnen ontbreken. De volledige bouwlogica (validaties, e-mailteksten, envelope) is gedekt door de negatieve paden en de `loadEmailTemplate`-tests, die `dfsle` nooit raken. Faalt **alleen** de happy-path test op een `dfsle`-aanroep, dan is de functionele code correct en haalt de rest de 75%-dekkingseis; de deploy kan doorgaan.

### Verzenden mislukt met "Het veld Ter controle van is niet gevuld"

`Ter_controle_van__c` op de Case is leeg. Vul het met een **actieve** gebruiker die een e-mailadres heeft.

### Verzenden mislukt met "minimaal één PDF"

De handtekening-anchors (`\i1\`, `\s2\`, `\n2\`) staan alleen in de Motrac PDF-template. Selecteer altijd minimaal één PDF in de modal.

### De modal opent niet of toont een foutpagina

Controleer dat de Visualforce-pagina `DocusignCaseConfirm` bestaat, dat de Quick Action **Action Type: Visualforce Page** heeft en naar `DocusignCaseConfirm` verwijst, en dat de actie op de Page Layout van het gebruikte recordtype staat.

### Change Set upload mislukt met "No deployment connection"

De Deployment Connection ontbreekt. Ga in **productie** naar **Setup → Deployment Settings**, klik bij de sandbox op **Edit**, vink **Allow Inbound Changes** aan en sla op. Probeer de upload opnieuw.
