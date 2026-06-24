public with sharing class DocusignCaseQuickActionController {

    // Toegestane bestandstypen: één bron van waarheid in de service-klasse.

    public class FileInfo {
        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public String title;
        @AuraEnabled public String extension;
        @AuraEnabled public Long fileSize;
        @AuraEnabled public Datetime createdDate;
    }

    public class PreviewResponse {
        @AuraEnabled public Id caseId;
        @AuraEnabled public String caseNumber;

        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;

        @AuraEnabled public Id contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String contactEmail;

        @AuraEnabled public Id controleurId;
        @AuraEnabled public String controleurName;
        @AuraEnabled public String controleurEmail;

        @AuraEnabled public List<FileInfo> files;

        @AuraEnabled public Boolean canSend;
        @AuraEnabled public List<String> errors;
    }

    @AuraEnabled(cacheable=true)
    public static PreviewResponse loadPreview(Id caseId) {

        PreviewResponse response = new PreviewResponse();
        response.caseId = caseId;
        response.canSend = true;
        response.errors = new List<String>();
        response.files = new List<FileInfo>();

        if (caseId == null) {
            response.canSend = false;
            response.errors.add('Case Id ontbreekt.');
            return response;
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
            response.canSend = false;
            response.errors.add('Case niet gevonden of geen toegang.');
            return response;
        }

        Case caseRecord = cases[0];

        response.caseNumber  = caseRecord.CaseNumber;
        response.accountId   = caseRecord.AccountId;
        response.accountName = caseRecord.Account != null ? caseRecord.Account.Name : null;
        response.contactId   = caseRecord.ContactId;
        response.contactName = caseRecord.Contact != null ? caseRecord.Contact.Name : null;
        response.contactEmail= caseRecord.Contact != null ? caseRecord.Contact.Email : null;

        if (response.accountId == null) {
            response.canSend = false;
            response.errors.add('Account ontbreekt op de Case.');
        }

        if (response.contactId == null) {
            response.canSend = false;
            response.errors.add('Contact ontbreekt op de Case.');
        } else if (String.isBlank(response.contactEmail)) {
            response.canSend = false;
            response.errors.add('Het Contact heeft geen e-mailadres.');
        }

        if (caseRecord.Ter_controle_van__c == null) {
            response.canSend = false;
            response.errors.add('Het veld Ter controle van is niet gevuld op deze Case.');
        } else {
            Id controleurId = caseRecord.Ter_controle_van__c;

            if (controleurId.getSObjectType() != User.SObjectType) {
                response.canSend = false;
                response.errors.add('Het veld Ter controle van verwijst niet naar een Salesforce-gebruiker.');
            } else {
                List<User> controleurs = [
                    SELECT Id, Name, Email, IsActive
                    FROM User
                    WHERE Id = :controleurId
                    WITH USER_MODE
                    LIMIT 1
                ];

                if (!controleurs.isEmpty()) {
                    response.controleurId    = controleurs[0].Id;
                    response.controleurName  = controleurs[0].Name;
                    response.controleurEmail = controleurs[0].Email;

                    if (!controleurs[0].IsActive) {
                        response.canSend = false;
                        response.errors.add('De controleur is geen actieve Salesforce-gebruiker.');
                    }
                    if (String.isBlank(controleurs[0].Email)) {
                        response.canSend = false;
                        response.errors.add('De controleur heeft geen e-mailadres.');
                    }
                }
            }
        }

        List<ContentDocumentLink> linkedFiles = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseRecord.Id
            WITH USER_MODE
        ];

        if (linkedFiles.isEmpty()) {
            response.canSend = false;
            response.errors.add('Geen Salesforce Files gevonden op deze Case.');
            return response;
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
            response.canSend = false;
            response.errors.add('Geen geschikte bestanden gevonden op deze Case. Toegestaan: ' + DocusignEnvelopeService.ALLOWED_EXTENSIONS_LABEL + '.');
            return response;
        }

        for (ContentVersion version : versions) {
            FileInfo info = new FileInfo();
            info.contentVersionId  = version.Id;
            info.contentDocumentId = version.ContentDocumentId;
            info.title             = version.Title;
            info.extension         = version.FileExtension;
            info.fileSize          = version.ContentSize;
            info.createdDate       = version.CreatedDate;
            response.files.add(info);
        }

        return response;
    }

    @AuraEnabled
    public static String sendEnvelope(Id caseId, Id contactId, List<Id> contentVersionIds) {

        PreviewResponse preview = loadPreview(caseId);

        if (!preview.canSend) {
            throw new AuraHandledException(String.join(preview.errors, '\n'));
        }

        if (contentVersionIds == null || contentVersionIds.isEmpty()) {
            throw new AuraHandledException('Selecteer minimaal één bestand om te versturen.');
        }

        // Optimistic lock: elke geselecteerde Id moet nog in de actuele
        // bestandslijst van de Case voorkomen (laatste versie, toegestaan type).
        Map<Id, String> extensionByVersionId = new Map<Id, String>();
        for (FileInfo info : preview.files) {
            extensionByVersionId.put(info.contentVersionId, info.extension);
        }
        Boolean selectionContainsPdf = false;
        for (Id selectedId : contentVersionIds) {
            if (!extensionByVersionId.containsKey(selectedId)) {
                throw new AuraHandledException(
                    'Eén of meer geselecteerde bestanden zijn gewijzigd of verwijderd sinds het openen van deze modal. Sluit dit venster en probeer opnieuw.'
                );
            }
            String extension = extensionByVersionId.get(selectedId);
            if (extension != null && extension.toLowerCase() == 'pdf') {
                selectionContainsPdf = true;
            }
        }
        if (!selectionContainsPdf) {
            throw new AuraHandledException(
                'Selecteer minimaal één PDF — de handtekening-anchors staan alleen in de PDF.'
            );
        }

        // Geef exact de gevalideerde selectie mee.
        DocusignEnvelopeService.sendFilesFromCase(caseId, contactId, contentVersionIds);

        return 'DocuSign-envelope is verzonden.';
    }
}
