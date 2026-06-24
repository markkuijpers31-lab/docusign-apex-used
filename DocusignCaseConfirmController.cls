public with sharing class DocusignCaseConfirmController {

    // Toegestane bestandstypen: één bron van waarheid in de service-klasse.
    // SOQL-stringvergelijking is case-insensitive, dus lowercase volstaat.

    /**
     * Wrapper voor één selecteerbaar bestand op de Case. De selected-vlag
     * is gebonden aan de checkbox op de Visualforce-pagina en reist mee
     * in de view state.
     */
    public class FileOption {
        public Boolean selected { get; set; }
        public Id contentVersionId { get; set; }
        public String title { get; set; }
        public String extension { get; set; }
        public Integer fileSize { get; set; }
        public Datetime createdDate { get; set; }

        public String getLabel() {
            return title + '.' + extension;
        }

        public String getSizeLabel() {
            if (fileSize == null) {
                return '';
            }
            if (fileSize < 1024) {
                return fileSize + ' B';
            }
            if (fileSize < 1048576) {
                return Decimal.valueOf(fileSize).divide(1024, 0) + ' KB';
            }
            return Decimal.valueOf(fileSize).divide(1048576, 1) + ' MB';
        }

        public String getCreatedDateLabel() {
            // format() rendert in de tijdzone van de ingelogde gebruiker.
            return (createdDate == null) ? '' : createdDate.format('dd-MM-yyyy HH:mm');
        }
    }

    public Id caseId { get; private set; }
    public String caseNumber { get; private set; }

    public Id accountId { get; private set; }
    public String accountName { get; private set; }

    public Id contactId { get; private set; }
    public String contactName { get; private set; }
    public String contactEmail { get; private set; }

    public Id controleurId { get; private set; }
    public String controleurName { get; private set; }
    public String controleurEmail { get; private set; }

    public List<FileOption> files { get; private set; }

    // Semicolon-separated ContentVersion Ids in de door de gebruiker
    // gesleepte volgorde. Wordt door JavaScript (SortableJS) in de modal
    // bijgewerkt op elk drop-event. Leeg/null = val terug op de standaard
    // CreatedDate DESC-volgorde uit loadFileOptions().
    public String orderedIds { get; set; }

    public List<String> errors { get; private set; }

    public Boolean sent { get; private set; }
    public String successMessage { get; private set; }

    // Voor tests: de volgorde waarin selectedIds naar de service is gegaan.
    @TestVisible
    private List<Id> lastSelectionSent;

    public DocusignCaseConfirmController(ApexPages.StandardController standardController) {
        this.caseId = standardController.getId();
        this.errors = new List<String>();
        this.files = new List<FileOption>();
        this.sent = false;

        validateCaseData();
        loadFileOptions();
    }

    /**
     * Valideert Case, Account, Contact en controleur. Reset de errors-lijst;
     * raakt de bestandslijst (en dus de selectie in de view state) NIET aan.
     */
    private void validateCaseData() {
        errors = new List<String>();

        caseNumber = null;
        accountId = null;  accountName = null;
        contactId = null;  contactName = null;  contactEmail = null;
        controleurId = null;  controleurName = null;  controleurEmail = null;

        if (caseId == null) {
            errors.add('Case Id ontbreekt.');
            return;
        }

        List<Case> cases = [
            SELECT Id, CaseNumber,
                   AccountId, Account.Name,
                   ContactId, Contact.Name, Contact.Email,
                   Ter_controle_van__c
            FROM Case
            WHERE Id = :caseId
            WITH USER_MODE
            LIMIT 1
        ];

        if (cases.isEmpty()) {
            errors.add('Case niet gevonden of geen toegang.');
            return;
        }

        Case caseRecord = cases[0];

        caseNumber  = caseRecord.CaseNumber;
        accountId   = caseRecord.AccountId;
        accountName = (caseRecord.Account != null) ? caseRecord.Account.Name : null;
        contactId   = caseRecord.ContactId;
        contactName = (caseRecord.Contact != null) ? caseRecord.Contact.Name : null;
        contactEmail= (caseRecord.Contact != null) ? caseRecord.Contact.Email : null;

        if (accountId == null) {
            errors.add('Account ontbreekt op de Case.');
        }

        if (contactId == null) {
            errors.add('Contact ontbreekt op de Case.');
        } else if (String.isBlank(contactEmail)) {
            errors.add('Het Contact heeft geen e-mailadres.');
        }

        if (caseRecord.Ter_controle_van__c == null) {
            errors.add('Het veld Ter controle van is niet gevuld op deze Case.');
        } else {
            controleurId = caseRecord.Ter_controle_van__c;
            if (controleurId.getSObjectType() != User.SObjectType) {
                errors.add('Het veld Ter controle van verwijst niet naar een Salesforce-gebruiker.');
            } else {
                List<User> controleurs = [
                    SELECT Id, Name, Email, IsActive
                    FROM User
                    WHERE Id = :controleurId
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (controleurs.isEmpty()) {
                    errors.add('De controleur kon niet geladen worden.');
                } else {
                    controleurName  = controleurs[0].Name;
                    controleurEmail = controleurs[0].Email;
                    if (!controleurs[0].IsActive) {
                        errors.add('De controleur is geen actieve Salesforce-gebruiker.');
                    }
                    if (String.isBlank(controleurs[0].Email)) {
                        errors.add('De controleur heeft geen e-mailadres.');
                    }
                }
            }
        }
    }

    /**
     * Laadt alle selecteerbare bestanden op de Case (toegestane extensies,
     * laatste versie, met inhoud). Wordt alleen bij het openen van de pagina
     * aangeroepen zodat de selectie van de gebruiker bewaard blijft.
     */
    private void loadFileOptions() {
        files = new List<FileOption>();

        if (caseId == null) {
            return;
        }

        List<ContentDocumentLink> linkedFiles = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId
            WITH USER_MODE
        ];

        if (linkedFiles.isEmpty()) {
            errors.add('Geen Salesforce Files gevonden op deze Case.');
            return;
        }

        Set<Id> contentDocumentIds = new Set<Id>();
        for (ContentDocumentLink linkedFile : linkedFiles) {
            contentDocumentIds.add(linkedFile.ContentDocumentId);
        }

        List<ContentVersion> versions = [
            SELECT Id, Title, FileExtension, ContentDocumentId, ContentSize, CreatedDate
            FROM ContentVersion
            WHERE ContentDocumentId IN :contentDocumentIds
            AND IsLatest = true
            AND FileExtension IN :DocusignEnvelopeService.ALLOWED_EXTENSIONS
            AND ContentSize > 0
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];

        if (versions.isEmpty()) {
            errors.add('Geen geschikte bestanden gevonden op deze Case. Toegestaan: ' + DocusignEnvelopeService.ALLOWED_EXTENSIONS_LABEL + '.');
            return;
        }

        for (ContentVersion version : versions) {
            FileOption option = new FileOption();
            option.selected         = false;
            option.contentVersionId = version.Id;
            option.title            = version.Title;
            option.extension        = version.FileExtension;
            option.fileSize         = version.ContentSize;
            option.createdDate      = version.CreatedDate;
            files.add(option);
        }
    }

    public Boolean getCanSend()    { return !sent && errors != null && errors.isEmpty() && !files.isEmpty(); }
    public Boolean getDisableSend(){ return !getCanSend(); }
    public Boolean getHasErrors()  { return errors != null && !errors.isEmpty(); }
    public Boolean getHasFiles()   { return files != null && !files.isEmpty(); }
    public Integer getFileCount()  { return (files == null) ? 0 : files.size(); }

    public String getAccountLabel() {
        return String.isBlank(accountName) ? 'Niet gevuld' : accountName;
    }

    public String getContactLabel() {
        if (String.isBlank(contactName)) return 'Niet gevuld';
        return String.isBlank(contactEmail) ? contactName : contactName + ' <' + contactEmail + '>';
    }

    public String getControleurLabel() {
        if (String.isBlank(controleurName)) return 'Niet gevuld';
        return String.isBlank(controleurEmail) ? controleurName : controleurName + ' <' + controleurEmail + '>';
    }

    public PageReference sendEnvelope() {

        // Guard tegen dubbele submit binnen dezelfde view state.
        if (sent) {
            return null;
        }

        // Selectie eerst uitlezen; validateCaseData() raakt de lijst niet aan.
        List<Id> selectedIds = new List<Id>();
        for (FileOption option : files) {
            if (option.selected == true) {
                selectedIds.add(option.contentVersionId);
            }
        }

        // Pas de drag-and-drop-volgorde toe als de UI er één heeft doorgegeven.
        // Items in orderedIds die niet geselecteerd zijn, worden overgeslagen.
        // Geselecteerde items die om een vreemde reden niet in orderedIds
        // voorkomen (bv. JS niet uitgevoerd) gaan achteraan, in hun
        // oorspronkelijke checkbox-volgorde.
        selectedIds = applyDragOrder(selectedIds, orderedIds);

        validateCaseData();

        if (getHasErrors()) {
            for (String errorMessage : errors) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, errorMessage));
            }
            return null;
        }

        if (selectedIds.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(
                ApexPages.Severity.ERROR,
                'Selecteer minimaal één bestand om te versturen.'
            ));
            return null;
        }

        // De handtekening-anchors (\i1\, \s2\, \n2\) staan alleen in de
        // PDF-template. Zonder PDF in de selectie zou dfsle luid falen;
        // geef hier vooraf een duidelijke melding aan de gebruiker.
        Boolean selectionContainsPdf = false;
        Set<Id> selectedIdSet = new Set<Id>(selectedIds);
        for (FileOption option : files) {
            if (selectedIdSet.contains(option.contentVersionId)
                && option.extension != null
                && option.extension.toLowerCase() == 'pdf') {
                selectionContainsPdf = true;
                break;
            }
        }
        if (!selectionContainsPdf) {
            ApexPages.addMessage(new ApexPages.Message(
                ApexPages.Severity.ERROR,
                'Selecteer minimaal één PDF — de handtekening-anchors staan alleen in de PDF.'
            ));
            return null;
        }

        // Optimistic lock: zijn de geselecteerde bestanden nog actueel,
        // toegestaan en aan deze Case gekoppeld?
        if (!isSelectionStillCurrent(selectedIds)) {
            ApexPages.addMessage(new ApexPages.Message(
                ApexPages.Severity.ERROR,
                'Eén of meer geselecteerde bestanden zijn gewijzigd of verwijderd sinds het openen van dit scherm. Sluit dit scherm en open de actie opnieuw.'
            ));
            return null;
        }

        try {
            // Geef exact de gevalideerde selectie mee; de service zoekt niet zelf.
            lastSelectionSent = selectedIds.clone();
            DocusignEnvelopeService.sendFilesFromCase(caseId, contactId, selectedIds);

            sent = true;
            successMessage = 'DocuSign-envelope is verzonden. Je kunt dit venster sluiten.';
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.CONFIRM, successMessage));
        } catch (Exception e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }

        return null;
    }

    /**
     * Herschikt de geselecteerde Ids volgens de drag-volgorde uit de UI.
     * orderedIdsRaw is een ';'-gescheiden string ContentVersion Ids (zoals
     * SortableJS de hidden input vult). Ongeldige tokens en niet-geselecteerde
     * Ids worden overgeslagen. Geselecteerde Ids die niet in orderedIdsRaw
     * voorkomen, behouden hun originele relatieve volgorde en komen achteraan.
     */
    @TestVisible
    private static List<Id> applyDragOrder(List<Id> selectedIds, String orderedIdsRaw) {
        if (String.isBlank(orderedIdsRaw) || selectedIds.isEmpty()) {
            return selectedIds;
        }

        Set<Id> selectedSet = new Set<Id>(selectedIds);
        Set<Id> placed = new Set<Id>();
        List<Id> reordered = new List<Id>();

        for (String token : orderedIdsRaw.split(';')) {
            String trimmed = token == null ? '' : token.trim();
            if (String.isBlank(trimmed)) {
                continue;
            }
            Id cvId;
            try {
                cvId = (Id) trimmed;
            } catch (System.StringException e) {
                continue;
            }
            if (selectedSet.contains(cvId) && !placed.contains(cvId)) {
                reordered.add(cvId);
                placed.add(cvId);
            }
        }

        // Eventueel geselecteerde items die de UI niet aandroeg: achteraan,
        // in hun oorspronkelijke volgorde uit de checkbox-lijst.
        for (Id cvId : selectedIds) {
            if (!placed.contains(cvId)) {
                reordered.add(cvId);
                placed.add(cvId);
            }
        }

        return reordered;
    }

    private Boolean isSelectionStillCurrent(List<Id> selectedIds) {
        Set<Id> linkedDocumentIds = new Set<Id>();
        for (ContentDocumentLink linkedFile : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId
            WITH USER_MODE
        ]) {
            linkedDocumentIds.add(linkedFile.ContentDocumentId);
        }

        Map<Id, ContentVersion> currentVersions = new Map<Id, ContentVersion>([
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :selectedIds
            AND IsLatest = true
            AND FileExtension IN :DocusignEnvelopeService.ALLOWED_EXTENSIONS
            AND ContentSize > 0
            WITH USER_MODE
        ]);

        for (Id selectedId : selectedIds) {
            ContentVersion version = currentVersions.get(selectedId);
            if (version == null || !linkedDocumentIds.contains(version.ContentDocumentId)) {
                return false;
            }
        }
        return true;
    }
}
