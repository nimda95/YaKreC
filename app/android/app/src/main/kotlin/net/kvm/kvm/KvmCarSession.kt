package net.kvm.kvm

import android.content.Intent
import androidx.car.app.Screen
import androidx.car.app.Session

class KvmCarSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen = KvmDisplayScreen(carContext)
}
