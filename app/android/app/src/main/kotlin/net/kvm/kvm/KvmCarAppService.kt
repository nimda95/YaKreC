package net.kvm.kvm

import androidx.car.app.CarAppService
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator

/**
 * Android Auto entry point. The host (DHU, Headunit Revived, the car) binds
 * this service when the user opens the app on the AA screen.
 */
class KvmCarAppService : CarAppService() {

    override fun createHostValidator(): HostValidator {
        // ALLOW_ALL_HOSTS is fine for personal-sideload use. For Play Store
        // we'd switch to the real Google host allowlist.
        return HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
    }

    override fun onCreateSession(): Session = KvmCarSession()
}
