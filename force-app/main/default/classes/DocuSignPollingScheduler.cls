/**
 * @description A self-chaining Schedulable class responsible for orchestrating continuous DocuSign polling.
 * This scheduler operates in two distinct modes to ensure high availability:
 * 1. Normal Mode: Runs every 2 minutes to execute the `DocuSignPollingService` batch, processing DocuSign updates.
 * 2. Watchdog Mode: Runs every 5 minutes to monitor the main polling job. If the main job fails or stops, 
 *    the watchdog restarts it. It also handles retrying failed PDF downloads.
 * Both modes automatically reschedule themselves upon completion. The class also provides static utility 
 * methods to start, stop, and monitor the health of these scheduled jobs.
 */
public without sharing class DocuSignPollingScheduler implements Schedulable {
    private static final String JOB_NAME = 'DocuSign_Polling';
    private static final String WATCHDOG_JOB_NAME = 'DocuSign_Polling_Watchdog';
    private static final Integer BATCH_SIZE = 50;
    // ── Execution mode 
    private final Boolean watchdogMode;
    // Default constructor — normal polling mode
    public DocuSignPollingScheduler() {
        this.watchdogMode = false;
    }
    // Boolean constructor — explicit mode selection
    public DocuSignPollingScheduler(Boolean watchdogMode) {
        this.watchdogMode = (watchdogMode == true);
    }
    public DocuSignPollingScheduler(Integer slot) {
        this.watchdogMode = (slot != null && slot == -1);
    }
    public void execute(SchedulableContext ctx) {
        try {
            if (watchdogMode) {
                //  WATCHDOG heartbeat 
                System.debug(LoggingLevel.INFO, '[DocuSignPollingScheduler] Watchdog heartbeat fired.');
                if (!isPollingActive()) {
                    System.debug(LoggingLevel.WARN, '[DocuSignPollingScheduler] Watchdog: main polling dead — restarting.');
                    startPolling();
                }
                try {
                    DocuSignPollingService.retryFailedPdfDownloads();
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, '[DocuSignPollingScheduler] Watchdog: retryFailedPdfDownloads failed: ' + e.getMessage());
                }
            } else {
                //  NORMAL polling 
                System.debug(LoggingLevel.INFO, '[DocuSignPollingScheduler] Polling fired — launching batch.');
                try {
                    Database.executeBatch(new DocuSignPollingService(), BATCH_SIZE);
                    System.debug(LoggingLevel.INFO, '[DocuSignPollingScheduler] Batch launched. Size=' + BATCH_SIZE);
                } catch (AsyncException e) {
                    System.debug(LoggingLevel.WARN, '[DocuSignPollingScheduler] Batch limit reached: ' + e.getMessage());
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, '[DocuSignPollingScheduler] Batch launch failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
                }
            }
        } finally {
            // SELF-CHAINING (Reschedule the next run)
            if (ctx != null) {
                try {
                    System.abortJob(ctx.getTriggerId());
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, '[DocuSignPollingScheduler] Failed to abort finished job: ' + e.getMessage());
                }
            }
            // Queue the next iteration
            if (watchdogMode) {
                startWatchdog();
            } else {
                startPolling();
            }
        }
    }
    /* STATIC MANAGEMENT METHODS */
    // Helper to build a valid Salesforce Cron String X minutes into the future
    private static String getNextCronString(Integer minutesFromNow) {
        Datetime nextRun = Datetime.now().addMinutes(minutesFromNow);
        return '0 ' + nextRun.minute() + ' ' + nextRun.hour() + ' ' + nextRun.day() + ' ' + nextRun.month() + ' ? ' + nextRun.year();
    }
    public static void startPolling() {
        stopPolling();
        if (isPollingActive()) {
            System.debug(LoggingLevel.WARN, '[DocuSignPollingScheduler] startPolling: active job still present after stop — skipping schedule.');
            return;
        }
        String cronString = getNextCronString(2);
        String uniqueJobName = JOB_NAME + '_' + Datetime.now().getTime();
        System.schedule(uniqueJobName, cronString, new DocuSignPollingScheduler(false));
        System.debug(LoggingLevel.INFO, '[DocuSignPollingScheduler] Polling started (next run in 2 mins).');
    }
    /** Stops all active polling jobs (does NOT touch the watchdog).*/
    public static void stopPolling() {
        String matchName = JOB_NAME + '%';
        String excludeName = WATCHDOG_JOB_NAME + '%';
        for (CronTrigger ct : [SELECT Id, CronJobDetail.Name FROM CronTrigger WHERE CronJobDetail.Name LIKE :matchName AND (NOT CronJobDetail.Name LIKE :excludeName) AND State NOT IN ('DELETED', 'ABORTED', 'COMPLETE')]) {
            try {
                System.abortJob(ct.Id);
                System.debug(LoggingLevel.INFO, '[DocuSignPollingScheduler] Aborted: ' + ct.CronJobDetail.Name);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[DocuSignPollingScheduler] Could not abort ' + ct.CronJobDetail.Name + ': ' + e.getMessage());
            }
        }
    }
    /** Returns true when at least one non-terminal polling job exists. */
    public static Boolean isPollingActive() {
        String matchName = JOB_NAME + '%';
        String excludeName = WATCHDOG_JOB_NAME + '%';
        return ![SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :matchName AND (NOT CronJobDetail.Name LIKE :excludeName) AND State NOT IN ('DELETED', 'ABORTED', 'COMPLETE') LIMIT 1 ].isEmpty();
    }
    
    /** Starts (or restarts) the watchdog job. */
    public static void startWatchdog() {
        stopWatchdog();
        if (isWatchdogActive()) {
            System.debug(LoggingLevel.WARN, '[DocuSignPollingScheduler] startWatchdog: active watchdog still present after stop — skipping schedule.');
            return;
        }
        String cronString = getNextCronString(5);
        String uniqueJobName = WATCHDOG_JOB_NAME + '_' + Datetime.now().getTime();
        try {
            System.schedule(uniqueJobName, cronString, new DocuSignPollingScheduler(true));
            System.debug(LoggingLevel.INFO, '[DocuSignPollingScheduler] Watchdog started (next run in 5 mins).');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocuSignPollingScheduler] Watchdog start failed: ' + e.getMessage());
        }
    }
    /** Stops the watchdog job. */
    public static void stopWatchdog() {
        String matchName = WATCHDOG_JOB_NAME + '%';
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE  CronJobDetail.Name LIKE :matchName AND State NOT IN ('DELETED', 'ABORTED', 'COMPLETE')]) {
            try { System.abortJob(ct.Id); } catch (Exception e) { }
        }
    }
    /** Returns true when the watchdog job is active. */
    public static Boolean isWatchdogActive() {
        String matchName = WATCHDOG_JOB_NAME + '%';
        return ![SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :matchName AND State NOT IN ('DELETED', 'ABORTED', 'COMPLETE')LIMIT 1].isEmpty();
    }
    /** Convenience: stop every DocuSign scheduled job including watchdog. */
    public static void stopAll() {
        stopPolling();
        stopWatchdog();
    }
}