public with sharing class OpportunityTriggerHandler extends TriggerHandler {

    public override void beforeInsert() {
        List<Opportunity> newOpps = (List<Opportunity>) Trigger.new;

        for (Opportunity opp : newOpps) {
            if (opp.Type == null) {
                opp.Type = 'New Customer';
            }
        }
    }

    public override void beforeUpdate() {
        List<Opportunity> newOpps = (List<Opportunity>) Trigger.new;
        Map<Id, Opportunity> oldMap = (Map<Id, Opportunity>) Trigger.oldMap;

        // Validate Amount > 5000
        for (Opportunity opp : newOpps) {
            if (opp.Amount < 5000) {
                opp.addError('Opportunity amount must be greater than 5000');
            }
        }

        // Set Primary Contact to CEO
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : newOpps) {
            if (opp.AccountId != null && opp.Primary_Contact__c == null) {
                accountIds.add(opp.AccountId);
            }
        }

        Map<Id, Contact> ceoContacts = new Map<Id, Contact>();
        for (Contact con : [
            SELECT Id, AccountId 
            FROM Contact 
            WHERE AccountId IN :accountIds AND Title = 'CEO'
            ORDER BY FirstName ASC
        ]) {
            if (!ceoContacts.containsKey(con.AccountId)) {
                ceoContacts.put(con.AccountId, con);
            }
        }

        for (Opportunity opp : newOpps) {
            if (opp.AccountId != null && opp.Primary_Contact__c == null && ceoContacts.containsKey(opp.AccountId)) {
                opp.Primary_Contact__c = ceoContacts.get(opp.AccountId).Id;
            }
        }

        // Append stage change to description
        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            if (opp.StageName != null && oldOpp.StageName != opp.StageName) {
                String appendText = '\nStage Change:' + opp.StageName + ':' + DateTime.now().format();
                opp.Description = (opp.Description == null) ? appendText : opp.Description + appendText;
            }
        }
    }

    public override void beforeDelete() {
        List<Opportunity> oldOpps = (List<Opportunity>) Trigger.old;

        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : oldOpps) {
            if (opp.AccountId != null && opp.StageName == 'Closed Won') {
                accountIds.add(opp.AccountId);
            }
        }

        Map<Id, Account> accountMap = new Map<Id, Account>(
            [SELECT Id, Industry FROM Account WHERE Id IN :accountIds]
        );

        for (Opportunity opp : oldOpps) {
            if (opp.StageName == 'Closed Won' && accountMap.get(opp.AccountId)?.Industry == 'Banking') {
                opp.addError('Cannot delete a closed won opportunity for a banking account');
            } else if (opp.IsClosed) {
                opp.addError('Cannot delete closed opportunity');
            }
        }
    }

    public override void afterInsert() {
        List<Opportunity> newOpps = (List<Opportunity>) Trigger.new;

        List<Task> tasks = new List<Task>();
        for (Opportunity opp : newOpps) {
            tasks.add(new Task(
                Subject = 'Call Primary Contact',
                WhatId = opp.Id,
                WhoId = opp.Primary_Contact__c,
                OwnerId = opp.OwnerId,
                ActivityDate = Date.today().addDays(3)
            ));
        }

        if (!tasks.isEmpty()) {
            insert tasks;
        }
    }

    public override void afterDelete() {
        notifyOwnersOpportunityDeleted((List<Opportunity>) Trigger.old);
    }

    public override void afterUndelete() {
        assignPrimaryContact((Map<Id, Opportunity>) Trigger.newMap);
    }

    private static void notifyOwnersOpportunityDeleted(List<Opportunity> opps) {
        Set<Id> ownerIds = new Set<Id>();
        for (Opportunity opp : opps) {
            ownerIds.add(opp.OwnerId);
        }

        Map<Id, User> userMap = new Map<Id, User>(
            [SELECT Id, Email FROM User WHERE Id IN :ownerIds]
        );

        List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
        for (Opportunity opp : opps) {
            User owner = userMap.get(opp.OwnerId);
            if (owner != null && owner.Email != null) {
                Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                mail.setToAddresses(new String[] { owner.Email });
                mail.setSubject('Opportunity Deleted : ' + opp.Name);
                mail.setPlainTextBody('Your Opportunity: ' + opp.Name + ' has been deleted.');
                mails.add(mail);
            }
        }

        if (!mails.isEmpty()) {
            try {
                Messaging.sendEmail(mails);
            } catch (Exception e) {
                System.debug('Email exception: ' + e.getMessage());
            }
        }
    }

    private static void assignPrimaryContact(Map<Id, Opportunity> oppNewMap) {
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : oppNewMap.values()) {
            if (opp.AccountId != null && opp.Primary_Contact__c == null) {
                accountIds.add(opp.AccountId);
            }
        }

        Map<Id, Contact> vpContacts = new Map<Id, Contact>();
        for (Contact con : [
            SELECT Id, AccountId 
            FROM Contact 
            WHERE Title = 'VP Sales' AND AccountId IN :accountIds
        ]) {
            if (!vpContacts.containsKey(con.AccountId)) {
                vpContacts.put(con.AccountId, con);
            }
        }

        List<Opportunity> oppsToUpdate = new List<Opportunity>();
        for (Opportunity opp : oppNewMap.values()) {
            if (opp.Primary_Contact__c == null && vpContacts.containsKey(opp.AccountId)) {
                oppsToUpdate.add(new Opportunity(
                    Id = opp.Id,
                    Primary_Contact__c = vpContacts.get(opp.AccountId).Id
                ));
            }
        }

        if (!oppsToUpdate.isEmpty()) {
            update oppsToUpdate;
        }
    }
}
