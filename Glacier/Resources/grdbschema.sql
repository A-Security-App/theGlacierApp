CREATE
    TABLE
        keyvalue (
            KEY TEXT NOT NULL
            ,collection TEXT NOT NULL
            ,VALUE BLOB NOT NULL
            ,PRIMARY KEY (
                KEY
                ,collection
            )
        )
;

CREATE
    TABLE
        IF NOT EXISTS "SMSAccount" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"twilioId" TEXT NOT NULL
            ,"phoneNumber" TEXT NOT NULL
            ,"displayName" TEXT
            ,"gradientAvatar" TEXT
            ,"color" TEXT
            ,"modified" DATE
        )
;

CREATE
    TABLE
        IF NOT EXISTS "SMSConversation" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"smsAccountId" TEXT 
            ,"firstName" TEXT
            ,"lastName" TEXT
            ,"preferredName" TEXT
            ,"avatarData" BLOB
            ,"remoteNumber" TEXT
            ,"localNumber" TEXT
            ,"latestMessage" TEXT 
            ,"latestMessageId" TEXT
            ,"latestMessageDate" DOUBLE
            ,"isRead" INTEGER
            ,"isNew" INTEGER 
            ,"twilioId" TEXT
            ,"modified" DATE
            , CONSTRAINT fk_smsaccount
                FOREIGN KEY (smsAccountId)
                REFERENCES SMSAccount(uniqueId)
                ON DELETE CASCADE
        )
;

CREATE
    TABLE
        IF NOT EXISTS "SMSMessage" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"conversationId" TEXT
            ,"twilioSid" TEXT 
            ,"messageDate" DOUBLE
            ,"isRead" INTEGER
            ,"isIncoming" INTEGER 
            ,"mediaItemUniqueId" TEXT
            ,"transferProgress" DOUBLE
            ,"msgText" TEXT
            ,"msgSenderId" TEXT
            ,"msgSenderDisplayName" TEXT
            ,"modified" DATE
            , CONSTRAINT fk_smsconversation
                FOREIGN KEY (conversationId)
                REFERENCES SMSConversation(uniqueId)
                ON DELETE CASCADE
        )
;

CREATE
    TABLE
        IF NOT EXISTS "SMSMediaItem" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"parentObjectKey" TEXT NOT NULL
            ,"parentObjectCollection" TEXT
            ,"parentThreadKey" TEXT NOT NULL
            ,"transferProgress" DOUBLE 
            ,"filename" TEXT
            ,"modified" DATE
            , CONSTRAINT fk_smsmessage
                FOREIGN KEY (parentObjectKey)
                REFERENCES SMSMessage(uniqueId)
                ON DELETE CASCADE
        )
;

CREATE
    TABLE
        IF NOT EXISTS "CallRecord" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"twilioSid" TEXT
            ,"name" TEXT
            ,"phoneNumber" TEXT
            ,"isIncoming" BOOLEAN NOT NULL DEFAULT 1
            ,"to" TEXT
            ,"toFormatted" TEXT
            ,"from" TEXT
            ,"fromFormatted" TEXT
            ,"status" TEXT
            ,"startTime" TEXT
            ,"endTime" TEXT
            ,"duration" TEXT
            ,"modified" DATE
        )
;

CREATE
    INDEX "index_CallRecord_on_twilioSid"
        ON "CallRecord"("twilioSid"
)
;

CREATE
    INDEX "index_SMSAccount_on_uniqueId"
        ON "SMSAccount"("uniqueId"
)
;

CREATE
    INDEX "index_SMSMessage_on_uniqueId"
        ON "SMSMessage"("uniqueId"
)
;

CREATE
    INDEX "index_SMSMessage_on_conversationId"
        ON "SMSMessage"("conversationId"
)
;

CREATE
    INDEX "index_SMSMessage_on_messageDate"
        ON "SMSMessage"("messageDate"
)
;

CREATE
    INDEX "index_SMSConversation_on_uniqueId"
        ON "SMSConversation"("uniqueId"
)
;

CREATE
    INDEX "index_SMSConversation_on_localPhone_remotePhone"
        ON "SMSConversation"("localNumber"
    ,"remoteNumber"
)
;

CREATE
    INDEX "index_SMSConversation_on_twilioId"
        ON "SMSConversation"("twilioId"
)
;

CREATE
    TABLE
        IF NOT EXISTS "glacierAccount" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"username" TEXT
            ,"useStageConsole" BOOLEAN NOT NULL DEFAULT 0
            ,"rebootReminderEnabled" BOOLEAN NOT NULL DEFAULT 1
            ,"dnsEncryptionEnabled" BOOLEAN NOT NULL DEFAULT 0
            ,"vpnEnabled" BOOLEAN NOT NULL DEFAULT 0
            ,"loginDate" DOUBLE
            ,"apiKey" TEXT
            ,"avatarData" BLOB
            ,"password" TEXT
            ,"modified" DATE
        )
;

CREATE
    INDEX "index_Account_on_accountKey"
        ON "glacierAccount"("uniqueId"
)
;
