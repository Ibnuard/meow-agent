package com.meowagent.meow_agent

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Native keep-alive worker. It does not execute workflows; it only makes sure
 * the native workflow foreground service is back up if Android killed the app
 * process between scheduled runs.
 */
class WorkflowKeepAliveWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    override fun doWork(): Result {
        return try {
            startWorkflowService(applicationContext)
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start workflow foreground service", e)
            Result.retry()
        }
    }

    companion object {
        private const val TAG = "WorkflowKeepAliveWorker"
        private const val UNIQUE_WORK_NAME = "meow_native_workflow_keep_alive"

        fun register(context: Context) {
            val request = PeriodicWorkRequestBuilder<WorkflowKeepAliveWorker>(
                15,
                TimeUnit.MINUTES
            ).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UNIQUE_WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_WORK_NAME)
        }

        fun startWorkflowService(context: Context, title: String? = null, text: String? = null) {
            val intent = Intent(context, WorkflowForegroundService::class.java).apply {
                putExtra(WorkflowForegroundService.EXTRA_TITLE, title ?: "Meow Agent")
                putExtra(
                    WorkflowForegroundService.EXTRA_TEXT,
                    text ?: "Workflow scheduler active"
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
