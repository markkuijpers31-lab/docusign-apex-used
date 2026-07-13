public with sharing class DocusignEnvelopeService {

    private static final Integer MAX_CHECKBOX_ANCHORS = 200;

    // Quote__c is een optioneel lookup-veld op Case dat niet in elke org of sandbox
    // aanwezig is. De check via Schema voorkomt compile- en runtime-fouten in omgevingen
    // zonder dit veld; het Q-nummer valt dan automatisch terug op CaseNumber.
    @TestVisible
    private static final Boolean HAS_QUOTE_FIELD =
        Schema.SObjectType.Case.fields.getMap().containsKey('quote__c');

    /**
     * Toegestane bestandstypen voor verzending via DocuSign. Centrale bron van
     * waarheid; de controllers verwijzen hierheen i.p.v. een eigen lijst te
     * onderhouden. Vergelijking gebeurt altijd lowercase.
     *
     * Deze lijst dekt de native door DocuSign ondersteunde bestandsformaten
     * (documenten, spreadsheets, presentaties, afbeeldingen). Zie
     * https://support.docusign.com/s/document-item?language=en_US&bundleId=pik1583277475390
     * voor de officiële lijst.
     *
     * List i.p.v. Set zodat de waarde rechtstreeks in een SOQL IN-binding
     * gebruikt kan worden vanuit de controllers.
     */
    public static final List<String> ALLOWED_EXTENSIONS = new List<String>{
        // Documenten / tekst
        'doc', 'docm', 'docx', 'dot', 'dotm', 'dotx',
        'pdf', 'rtf', 'txt',
        'htm', 'html',
        'msg',
        'wpd', 'wps', 'wpt',
        'xps',
        // Spreadsheets
        'csv', 'xls', 'xlsm', 'xlsx',
        // Presentaties
        'pot', 'potx', 'pps', 'ppt', 'pptm', 'pptx',
        // Afbeeldingen
        'bmp', 'gif', 'jpg', 'jpeg', 'png', 'tif', 'tiff',
        // Overige
        'xml'
    };

    public static final String ALLOWED_EXTENSIONS_LABEL =
        'Word (DOC, DOCX), Excel (XLS, XLSX, CSV), PowerPoint (PPT, PPTX), PDF, RTF, TXT, HTML, MSG, afbeeldingen (PNG, JPG, GIF, TIFF, BMP) en XPS/XML';

    /**
     * Custom exception zodat foutmeldingen in een Visualforce-context leesbaar
     * blijven. AuraHandledException levert buiten Aura/LWC vaak
     * "Script-thrown exception" op i.p.v. de echte boodschap.
     */
    public class DocusignSendException extends Exception {}

    /**
     * Publieke entry point. Bouwt de envelope met de geselecteerde bestanden
     * en verstuurt deze. De callout wordt overgeslagen tijdens tests, zodat
     * de bouwlogica gedekt kan worden zonder DocuSign aan te roepen.
     *
     * @param caseId             Case waaraan de envelope gekoppeld wordt.
     * @param contactId          Optioneel; valt terug op Case.ContactId.
     * @param contentVersionIds  De IDs van de door de gebruiker geselecteerde
     *                           en reeds gevalideerde bestanden (van de
     *                           confirm-pagina). De service zoekt NIET zelf
     *                           bestanden bij elkaar.
     */
    public static void sendFilesFromCase(Id caseId, Id contactId, List<Id> contentVersionIds) {

        dfsle.Envelope envelope = buildEnvelope(caseId, contactId, contentVersionIds);

        // Callout niet uitvoeren in testcontext; bouwlogica is wel gedekt.
        if (Test.isRunningTest()) {
            return;
        }

        dfsle.Envelope sentEnvelope = dfsle.EnvelopeService.sendEnvelope(envelope, true);
        System.debug(LoggingLevel.INFO, 'DocuSign Envelope verzonden: ' + sentEnvelope.docuSignId);
    }

    /**
     * Bouwt de volledige envelope. Geen callout. Apart gehouden voor testbaarheid.
     */
    @TestVisible
    private static dfsle.Envelope buildEnvelope(Id caseId, Id contactId, List<Id> contentVersionIds) {

        if (caseId == null) {
            throw new DocusignSendException('Case Id ontbreekt.');
        }

        // Dedupliceren met behoud van volgorde; null-entries overslaan.
        List<Id> uniqueContentVersionIds = new List<Id>();
        Set<Id> seenIds = new Set<Id>();
        if (contentVersionIds != null) {
            for (Id cvId : contentVersionIds) {
                if (cvId != null && !seenIds.contains(cvId)) {
                    seenIds.add(cvId);
                    uniqueContentVersionIds.add(cvId);
                }
            }
        }
        if (uniqueContentVersionIds.isEmpty()) {
            throw new DocusignSendException('Geen bestanden geselecteerd om te versturen.');
        }

        Case caseRecord = loadCase(caseId);

        // ----- Signer 1: controleur -----
        // Niet Case Owner gebruiken; die kan een Queue zijn. Gebruik Ter_controle_van__c.
        if (caseRecord.Ter_controle_van__c == null) {
            throw new DocusignSendException('Het veld Ter controle van is niet gevuld op deze Case.');
        }

        Id controleurId = caseRecord.Ter_controle_van__c;
        if (controleurId.getSObjectType() != User.SObjectType) {
            throw new DocusignSendException('Het veld Ter controle van verwijst niet naar een Salesforce-gebruiker.');
        }

        User controleur = loadControleur(controleurId);
        if (!controleur.IsActive) {
            throw new DocusignSendException('De controleur is geen actieve Salesforce-gebruiker.');
        }
        if (String.isBlank(controleur.Email)) {
            throw new DocusignSendException('De controleur heeft geen e-mailadres.');
        }

        // ----- Signer 2: klantcontact -----
        Id signerContactId = (contactId != null) ? contactId : caseRecord.ContactId;
        if (signerContactId == null) {
            throw new DocusignSendException('Contact Id ontbreekt en deze Case heeft geen Contact gekoppeld.');
        }

        Contact signerContact = loadContact(signerContactId);
        if (String.isBlank(signerContact.Email)) {
            throw new DocusignSendException('Het gekozen Contact heeft geen e-mailadres.');
        }

        // ----- Bestanden valideren (exact de Ids die de gebruiker bevestigde) -----
        List<ContentVersion> selectedFiles = loadFiles(uniqueContentVersionIds);

        // De verplichte handtekening-anchors (\i1\, \s2\, \n2\) staan alleen
        // in de Motrac-PDF-template. Zonder een PDF in de selectie zou dfsle
        // luid falen met een onduidelijke foutmelding; deze check geeft een
        // bruikbare melding aan elke aanroeper (UI én directe service-calls).
        Boolean selectionContainsPdf = false;
        for (ContentVersion file : selectedFiles) {
            if (file.FileExtension != null && file.FileExtension.toLowerCase() == 'pdf') {
                selectionContainsPdf = true;
                break;
            }
        }
        if (!selectionContainsPdf) {
            throw new DocusignSendException(
                'Voor de handtekening-anchors is minimaal één PDF in de selectie vereist.'
            );
        }

        // ----- E-mail teksten -----
        String caseLabel = 'Case ' + caseRecord.CaseNumber;
        String quoteNumber = caseRecord.CaseNumber;
        if (HAS_QUOTE_FIELD) {
            SObject quoteRef = caseRecord.getSObject('Quote__r');
            if (quoteRef != null) {
                String qName = (String) quoteRef.get('Name');
                if (String.isNotBlank(qName)) {
                    quoteNumber = qName;
                }
            }
        }
        Boolean multipleDocuments = selectedFiles.size() > 1;
        String documentWord = multipleDocuments ? 'de documenten' : 'het document';
        String documentRef  = multipleDocuments ? 'deze documenten' : 'dit document';

        String recordTypeName = (caseRecord.RecordType != null) ? caseRecord.RecordType.DeveloperName : null;
        EmailTemplate emailTemplate = loadEmailTemplate(recordTypeName);

        String controleurSubject = emailTemplate.controleurSubject.replace('{quoteNumber}', quoteNumber);
        String controleurMessage = emailTemplate.controleurBody
            .replace('{quoteNumber}', quoteNumber)
            .replace('{controleurName}', controleur.Name)
            .replace('{contactName}', signerContact.Name);

        String contactSubject = emailTemplate.contactSubject.replace('{quoteNumber}', quoteNumber);
        String contactMessage = emailTemplate.contactBody
            .replace('{quoteNumber}', quoteNumber)
            .replace('{controleurName}', controleur.Name)
            .replace('{contactName}', signerContact.Name)
            .replace('{documentWord}', documentWord)
            .replace('{documentRef}', documentRef);

        // ----- Envelope -----
        dfsle.Envelope envelope = dfsle.EnvelopeService.getEmptyEnvelope(
            new dfsle.Entity(caseRecord.Id)
        );

        // RECIPIENT 1: Controleur (tekent eerst, krijgt \i1\)
        // ignoreIfNotPresent = false -> faalt luid als de anchor ontbreekt
        // i.p.v. de verplichte handtekening stil te droppen.
        dfsle.Tab controleurInitialTab = new dfsle.InitialHereTab()
            .withScale(1.0)
            .withRequired(true)
            .withAnchor(new dfsle.Tab.Anchor(
                '\\i1\\', false, false, 'right', false, false, 'pixels', 0, 0));

        dfsle.Recipient.EmailSettings controleurEmailSettings =
            new dfsle.Recipient.EmailSettings(null, null, controleurSubject, controleurMessage);

        dfsle.Recipient controleurRecipient = dfsle.Recipient.fromSource(
                controleur.Name, controleur.Email, null, 'Controleur', new dfsle.Entity(controleur.Id))
            .withRoutingOrder(1)
            .withEmailSettings(controleurEmailSettings)
            .withTabs(new List<dfsle.Tab>{ controleurInitialTab });

        // RECIPIENT 2: Contact / klant (tekent na controleur)
        // Verplichte tabs (\s2\, \n2\) -> ignoreIfNotPresent = false
        // Anchors gelden envelope-breed: DocuSign zoekt de anchor-tekst in
        // ALLE meegestuurde documenten.
        dfsle.Tab contactSignHereTab = new dfsle.SignHereTab()
            .withScale(1.0)
            .withRequired(true)
            .withAnchor(new dfsle.Tab.Anchor(
                '\\s2\\', false, false, 'right', false, false, 'pixels', -18, -28));

        dfsle.Tab contactNameTab = new dfsle.TextTab()
            .withRequired(true)
            .withName('contact_signer_name')
            .withDataLabel('contact_signer_name')
            .withAnchor(new dfsle.Tab.Anchor(
                '\\n2\\', false, false, 'right', false, false, 'pixels', -30, -8));

        // Optioneel referentieveld -> ignoreIfNotPresent = true mag blijven
        dfsle.Tab contactReferenceTab = new dfsle.TextTab()
            .withRequired(false)
            .withName('customer_reference')
            .withDataLabel('customer_reference')
            .withAnchor(new dfsle.Tab.Anchor(
                '\\ref2\\', false, false, 'right', true, true, 'pixels', -30, -8));

        List<dfsle.Tab> contactTabs = new List<dfsle.Tab>{
            contactSignHereTab,
            contactNameTab,
            contactReferenceTab
        };
        contactTabs.addAll(buildCheckboxTabsForContact(MAX_CHECKBOX_ANCHORS));

        dfsle.Recipient.EmailSettings contactEmailSettings =
            new dfsle.Recipient.EmailSettings(null, null, contactSubject, contactMessage);

        dfsle.Recipient contactRecipient = dfsle.Recipient.fromSource(
                signerContact.Name, signerContact.Email, null, 'CustomerSigner', new dfsle.Entity(signerContact.Id))
            .withRoutingOrder(2)
            .withEmailSettings(contactEmailSettings)
            .withTabs(contactTabs);

        envelope = envelope.withRecipients(new List<dfsle.Recipient>{
            controleurRecipient, contactRecipient
        });

        // Documenten: GEEN AcroForm-transformatie. Checkboxen via expliciete anchors.
        // Per ContentVersion Id één keer ophalen. Dat houdt de volgorde
        // deterministisch (== UI-volgorde uit de modal) en vermijdt het
        // matchen op dfsle.Document.sourceId, die in test-context null
        // is en NPE veroorzaakte. Geen callout; binnen Apex-governors voor
        // typische selectiegroottes (N < 10).
        List<dfsle.Document> orderedDocs = new List<dfsle.Document>();
        if (!Test.isRunningTest()) {
            for (Id cvId : uniqueContentVersionIds) {
                List<dfsle.Document> oneDoc = dfsle.DocumentService.getDocuments(
                    ContentVersion.getSObjectType(),
                    new Set<Id>{ cvId }
                );
                if (oneDoc.isEmpty()) {
                    throw new DocusignSendException(
                        'DocuSign kon één van de geselecteerde bestanden niet laden. Open het scherm opnieuw en probeer nogmaals.'
                    );
                }
                orderedDocs.add(oneDoc[0]);
            }
        }

        envelope = envelope.withDocuments(orderedDocs);
        envelope = envelope.withEmail(
            'DocuSign voorstel - ' + caseLabel,
            (multipleDocuments ? 'Deze documenten worden' : 'Dit document wordt') +
            ' via DocuSign ter controle en ondertekening aangeboden.'
        );

        return envelope;
    }

    // ------------------------------------------------------------------
    // SOQL helpers (allemaal WITH USER_MODE voor FLS/sharing-enforcement)
    // ------------------------------------------------------------------

    private static Case loadCase(Id caseId) {
        String optionalQuoteFields = HAS_QUOTE_FIELD ? ', Quote__c, Quote__r.Name' : '';
        String soql =
            'SELECT Id, CaseNumber, Subject, ContactId, Ter_controle_van__c, RecordType.DeveloperName' +
            optionalQuoteFields +
            ' FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1';
        List<Case> cases = Database.query(soql);
        if (cases.isEmpty()) {
            throw new DocusignSendException('Case niet gevonden of geen toegang.');
        }
        return cases[0];
    }

    private static User loadControleur(Id controleurId) {
        List<User> users = [
            SELECT Id, Name, Email, IsActive
            FROM User
            WHERE Id = :controleurId
            WITH USER_MODE
            LIMIT 1
        ];
        if (users.isEmpty()) {
            throw new DocusignSendException('De controleur kon niet geladen worden.');
        }
        return users[0];
    }

    private static Contact loadContact(Id contactId) {
        List<Contact> contacts = [
            SELECT Id, Name, FirstName, LastName, Email
            FROM Contact
            WHERE Id = :contactId
            WITH USER_MODE
            LIMIT 1
        ];
        if (contacts.isEmpty()) {
            throw new DocusignSendException('Het gekozen Contact kon niet geladen worden.');
        }
        return contacts[0];
    }

    /**
     * Laadt en valideert de geselecteerde bestanden. Elk bestand moet nog de
     * laatste versie zijn (optimistic lock: een nieuw geüploade versie maakt
     * het oude ContentVersion-id ongeldig), een toegestaan bestandstype hebben
     * en inhoud bevatten. Retourneert de bestanden in de volgorde van de input.
     */
    private static List<ContentVersion> loadFiles(List<Id> contentVersionIds) {
        Map<Id, ContentVersion> versionsById = new Map<Id, ContentVersion>([
            SELECT Id, Title, FileExtension, ContentDocumentId, ContentSize
            FROM ContentVersion
            WHERE Id IN :contentVersionIds
            AND IsLatest = true
            WITH USER_MODE
        ]);

        Set<String> allowedExtensionsLookup = new Set<String>(ALLOWED_EXTENSIONS);

        List<ContentVersion> orderedFiles = new List<ContentVersion>();
        for (Id cvId : contentVersionIds) {
            ContentVersion file = versionsById.get(cvId);
            if (file == null) {
                throw new DocusignSendException(
                    'Eén of meer geselecteerde bestanden bestaan niet meer of zijn niet de laatste versie. Open het scherm opnieuw.'
                );
            }
            if (file.FileExtension == null || !allowedExtensionsLookup.contains(file.FileExtension.toLowerCase())) {
                throw new DocusignSendException(
                    'Bestand "' + file.Title + '" heeft geen toegestaan bestandstype. Toegestaan: ' + ALLOWED_EXTENSIONS_LABEL + '.'
                );
            }
            if (file.ContentSize == null || file.ContentSize == 0) {
                throw new DocusignSendException('Bestand "' + file.Title + '" heeft geen inhoud.');
            }
            orderedFiles.add(file);
        }
        return orderedFiles;
    }

    /**
     * E-mailtemplate als plain wrapper, losgekoppeld van de exacte veld-API-namen
     * op DocusignEmailTemplate__mdt. Hierdoor compileert en werkt de service
     * ongeacht of de velden met of zonder underscore zijn aangemaakt
     * (bv. ControleurSubject__c vs. Controleur_Subject__c).
     */
    public class EmailTemplate {
        public String controleurSubject;
        public String controleurBody;
        public String contactSubject;
        public String contactBody;
    }

    /**
     * Mogelijke API-namen van het Custom Metadata Type zelf, in volgorde van
     * voorkeur. Net als bij de velden kan een spatie in het label de API-naam
     * met underscores opleveren (Docusign_Email_Template__mdt). Door het type
     * dynamisch op te lossen, blijft de code compileren ongeacht de naam.
     */
    private static final List<String> TYPE_NAME_CANDIDATES = new List<String>{
        'DocusignEmailTemplate__mdt', 'Docusign_Email_Template__mdt'
    };

    /**
     * Mogelijke veld-API-namen per logisch veld, in volgorde van voorkeur.
     * De eerste die in de org bestaat wordt gebruikt. Dit vangt verschillen op
     * die ontstaan wanneer een admin de velden handmatig aanmaakt: Salesforce
     * zet spaties in het Field Label om naar underscores in de API-naam, en er
     * kan een typefout insluipen (Contac_Body__c). De voorkeursnaam (zonder
     * underscore) komt overeen met de velddefinities in deze repo.
     */
    private static final Map<String, List<String>> TEMPLATE_FIELD_CANDIDATES =
        new Map<String, List<String>>{
            'RecordTypeDeveloperName' => new List<String>{ 'RecordTypeDeveloperName__c', 'Record_Type_Developer_Name__c' },
            'ControleurSubject'       => new List<String>{ 'ControleurSubject__c', 'Controleur_Subject__c' },
            'ControleurBody'          => new List<String>{ 'ControleurBody__c', 'Controleur_Body__c' },
            'ContactSubject'          => new List<String>{ 'ContactSubject__c', 'Contact_Subject__c' },
            'ContactBody'             => new List<String>{ 'ContactBody__c', 'Contact_Body__c', 'Contac_Body__c' }
        };

    /**
     * Zoekt het Custom Metadata Type op via getGlobalDescribe(), zodat er geen
     * statische verwijzing naar de typenaam in de code staat. Geeft null terug
     * als geen van de kandidaat-namen bestaat.
     */
    private static Schema.SObjectType resolveTemplateType() {
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        for (String candidate : TYPE_NAME_CANDIDATES) {
            Schema.SObjectType sObjectType = globalDescribe.get(candidate.toLowerCase());
            if (sObjectType != null) {
                return sObjectType;
            }
        }
        return null;
    }

    /**
     * Bepaalt voor elk logisch veld de werkelijke API-naam zoals die op het type
     * bestaat. Logische velden die niet gevonden worden, ontbreken in de Map.
     */
    private static Map<String, String> resolveTemplateFields(Map<String, Schema.SObjectField> fieldMap) {
        Map<String, String> resolved = new Map<String, String>();
        for (String logicalName : TEMPLATE_FIELD_CANDIDATES.keySet()) {
            for (String candidate : TEMPLATE_FIELD_CANDIDATES.get(logicalName)) {
                if (fieldMap.containsKey(candidate.toLowerCase())) {
                    resolved.put(logicalName, candidate);
                    break;
                }
            }
        }
        return resolved;
    }

    /**
     * Zoekt de e-mailtemplate op voor het opgegeven Case-recordtype. Zowel het
     * type als de velden worden dynamisch opgelost, zodat afwijkende API-namen
     * geen compile- of runtime-fout veroorzaken. Geeft een generieke fallback
     * terug als er geen (volledig) metadata-record bestaat, zodat de service
     * altijd werkt.
     */
    @TestVisible
    private static EmailTemplate loadEmailTemplate(String recordTypeName) {
        EmailTemplate template = defaultTemplate();

        Schema.SObjectType templateType = resolveTemplateType();
        if (String.isBlank(recordTypeName) || templateType == null) {
            return template;
        }

        Schema.DescribeSObjectResult typeDescribe = templateType.getDescribe();
        String typeName = typeDescribe.getName();
        Map<String, String> fields = resolveTemplateFields(typeDescribe.fields.getMap());

        Boolean canQuery = fields.containsKey('RecordTypeDeveloperName')
            && fields.containsKey('ControleurSubject')
            && fields.containsKey('ControleurBody')
            && fields.containsKey('ContactSubject')
            && fields.containsKey('ContactBody');

        if (canQuery) {
            String soql =
                'SELECT ' + fields.get('ControleurSubject') + ', ' + fields.get('ControleurBody') +
                ', ' + fields.get('ContactSubject') + ', ' + fields.get('ContactBody') +
                ' FROM ' + typeName +
                ' WHERE ' + fields.get('RecordTypeDeveloperName') + ' = :recordTypeName' +
                ' LIMIT 1';
            List<SObject> rows = Database.query(soql);
            if (!rows.isEmpty()) {
                SObject row = rows[0];
                // Alleen niet-lege waarden overschrijven de fallback, zodat een
                // half ingevuld record niet tot lege e-mails leidt.
                String cs = (String) row.get(fields.get('ControleurSubject'));
                String cb = (String) row.get(fields.get('ControleurBody'));
                String ks = (String) row.get(fields.get('ContactSubject'));
                String kb = (String) row.get(fields.get('ContactBody'));
                if (String.isNotBlank(cs)) template.controleurSubject = cs;
                if (String.isNotBlank(cb)) template.controleurBody = cb;
                if (String.isNotBlank(ks)) template.contactSubject = ks;
                if (String.isNotBlank(kb)) template.contactBody = kb;
            }
        }
        return template;
    }

    /**
     * Generieke fallback-teksten; gebruikt als er geen (volledig) metadata-record
     * bestaat voor het recordtype.
     */
    private static EmailTemplate defaultTemplate() {
        EmailTemplate template = new EmailTemplate();
        template.controleurSubject = 'Document(en) ter controle - {quoteNumber}';
        template.controleurBody =
            'Beste {controleurName},\n\n' +
            'Bijgaand ontvang je ter controle een document met referentie {quoteNumber}.\n\n' +
            'Bekijk het document zorgvuldig en teken af indien alles akkoord is.\n\n' +
            'Met vriendelijke groet,\n' +
            'Motrac';
        template.contactSubject = 'Officieel voorstel van Motrac - {quoteNumber}';
        template.contactBody =
            'Beste {contactName},\n\n' +
            'Hierbij delen wij ons officiële voorstel. U kunt middels onderstaande knop {documentWord} controleren en indien deze aan uw wensen voldoen ondertekenen.\n\n' +
            'Mocht u nog vragen hebben over {documentRef} dan kunt u terecht bij uw contactpersoon.\n\n' +
            'Met vriendelijke groet,\n\n' +
            'Namens {controleurName}\n' +
            'Motrac';
        return template;
    }

    @TestVisible
    private static List<dfsle.Tab> buildCheckboxTabsForContact(Integer maxCheckboxes) {
        List<dfsle.Tab> checkboxTabs = new List<dfsle.Tab>();
        if (maxCheckboxes == null || maxCheckboxes <= 0) {
            return checkboxTabs;
        }

        for (Integer i = 1; i <= maxCheckboxes; i++) {
            String numberPart = String.valueOf(i).leftPad(3, '0');
            String anchor = '\\cb_' + numberPart + '\\';
            // Unieke naam + data label per checkbox, anders koppelt DocuSign ze.
            String checkboxLabel = 'motrac_cb_' + numberPart;

            // Checkboxen zijn optioneel aanwezig -> ignoreIfNotPresent = true.
            dfsle.Tab checkboxTab = new dfsle.CheckboxTab()
                .withName(checkboxLabel)
                .withDataLabel(checkboxLabel)
                .withAnchor(new dfsle.Tab.Anchor(
                    anchor, false, false, 'right', true, true, 'pixels', -24, -1));

            checkboxTabs.add(checkboxTab);
        }
        return checkboxTabs;
    }
}
