/**
 * Resolves the configured question set for a matter.
 *
 * `Lead_Question__mdt` records are keyed by Matter Type and an optional Sub
 * Type. A Lead uses the Sub Type record when one is configured for its sub
 * type, and otherwise falls back to the Matter Type level record.
 *
 * SOQL against a Custom Metadata Type does not count toward the query limit,
 * and Custom Metadata carries no CRUD or FLS -- every user has read access, so
 * there is nothing for `USER_MODE` to enforce here.
 */
public with sharing class LeadQuestionSelector {

    /** Sub Type value that means "this matter type has no sub types". */
    private static final String NA_SUB_TYPE = 'N/A';

    /**
     * Test seam. Custom Metadata records cannot be inserted in a test, so tests
     * set question sets here instead of depending on whatever the org contains.
     */
    @TestVisible
    private static List<Lead_Question__mdt> mockConfigs;

    /** True when the value names a real sub type rather than "no sub type". */
    public static Boolean isRealSubType(String subType) {
        return String.isNotBlank(subType) && subType != NA_SUB_TYPE;
    }

    /**
     * The question set that applies to this matter, or null when none is
     * configured. An exact Sub Type match wins; otherwise the Matter Type level
     * record is used.
     */
    public static Lead_Question__mdt findFor(String matterType, String subType) {
        Lead_Question__mdt typeLevel;

        for (Lead_Question__mdt config : candidates(matterType, subType)) {
            // The mock list is not filtered by the database, so match here.
            if (config.Matter_Type__c != matterType) {
                continue;
            }
            if (isRealSubType(subType) && config.Sub_Type__c == subType) {
                return config;
            }
            if (typeLevel == null && !isRealSubType(config.Sub_Type__c)) {
                typeLevel = config;
            }
        }
        return typeLevel;
    }

    /**
     * Both the sub type record and the type level record in one query, so the
     * fallback costs nothing extra and the two SELECT lists cannot drift apart.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static List<Lead_Question__mdt> candidates(String matterType, String subType) {
        if (mockConfigs != null) {
            return mockConfigs;
        }
        String wanted = isRealSubType(subType) ? subType : NA_SUB_TYPE;
        return [
            SELECT Matter_Type__c, Sub_Type__c,
                   Question_1__c, Question_2__c, Question_3__c, Question_4__c,
                   Question_5__c, Question_6__c, Question_7__c, Question_8__c,
                   Question_9__c, Question_10__c, Question_11__c, Question_12__c,
                   Question_13__c, Question_14__c, Question_15__c
            FROM Lead_Question__mdt
            WHERE Matter_Type__c = :matterType
              AND (Sub_Type__c = :wanted OR Sub_Type__c = NULL OR Sub_Type__c = :NA_SUB_TYPE)
            ORDER BY Label
        ];
    }
}
