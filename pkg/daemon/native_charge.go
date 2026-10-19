package daemon

import (
	"net/http"
	"slices"

	"github.com/charlie0129/batt/pkg/compatibility"
	"github.com/charlie0129/batt/pkg/powerui"
	"github.com/gin-gonic/gin"
	"github.com/sirupsen/logrus"
)

var nativeCharge interface {
	Read() (powerui.State, error)
	SetLimit(int) error
}

// customChargeLimits extend Apple's 80–100 choices downwards; they are
// enforced by the charge hold, so they exist only with ChargeHold.
var customChargeLimits = []int{50, 55, 60, 65, 70, 75}

func setNativeLimit(c *gin.Context, limit int) {
	if !slices.Contains(capabilities.SupportedLimits, limit) {
		c.AbortWithStatusJSON(http.StatusBadRequest, "Choose one of the supported charge limits")
		return
	}
	maintainLoopInnerLock.Lock()
	defer maintainLoopInnerLock.Unlock()
	if slices.Contains(customChargeLimits, limit) {
		if heatHold == nil {
			c.AbortWithStatusJSON(http.StatusConflict, "Limits below 80% need charge-hold support")
			return
		}
		old := conf.CustomChargeLimit()
		conf.SetCustomChargeLimit(limit)
		if err := conf.Save(); err != nil {
			conf.SetCustomChargeLimit(old)
			c.AbortWithStatusJSON(http.StatusInternalServerError, err.Error())
			return
		}
		// Apple's 80% stays underneath as the backstop if the hold is lost.
		if heatHold.holder.Active() {
			heatHold.pendingLimit = 80
		} else if err := nativeCharge.SetLimit(80); err != nil {
			logrus.WithError(err).Warn("set Apple backstop limit")
		}
		heatHold.reconcile(conf.HeatProtectionEnabled(), conf.HeatPauseTemperatureCelsius(), conf.HeatResumeTemperatureCelsius())
		if status := getHeatProtectionStatus(); status.Fault {
			c.AbortWithStatusJSON(http.StatusServiceUnavailable, status.LastError)
			return
		}
		c.IndentedJSON(http.StatusCreated, "Charge limit set")
		return
	}
	if conf.CustomChargeLimit() > 0 {
		conf.SetCustomChargeLimit(0)
		if err := conf.Save(); err != nil {
			c.AbortWithStatusJSON(http.StatusInternalServerError, err.Error())
			return
		}
		if heatHold != nil && heatHold.holder.Active() {
			heatHold.pendingLimit = limit
			heatHold.reconcile(conf.HeatProtectionEnabled(), conf.HeatPauseTemperatureCelsius(), conf.HeatResumeTemperatureCelsius())
			c.IndentedJSON(http.StatusCreated, "Charge limit set")
			return
		}
	}
	// An active hold owns mclLimitValue. Releasing it for every change would
	// pulse the adapter on each slider step, so keep the new limit pending
	// and apply it when the hold ends.
	if heatHold != nil && heatHold.holder.Active() {
		heatHold.pendingLimit = limit
		c.IndentedJSON(http.StatusCreated, "Charge limit saved; it applies once the battery cools")
		return
	}
	if err := nativeCharge.SetLimit(limit); err != nil {
		c.AbortWithStatusJSON(http.StatusServiceUnavailable, err.Error())
		return
	}
	c.IndentedJSON(http.StatusCreated, "Apple native charge limit updated and verified")
}

func resetChargeControlOnShutdown() {
	// The system owns native charge limits. Exiting WattNook must preserve them.
	if capabilities.ChargeControlMode == compatibility.ChargeControlNative {
		maintainLoopInnerLock.Lock()
		defer maintainLoopInnerLock.Unlock()
		if heatHold != nil {
			if err := heatHold.release(); err != nil {
				logrus.WithError(err).Error("release charge hold before shutdown")
			}
		}
		if nativeThermal != nil {
			nativeThermal.stopping = true
			if err := nativeThermal.configure(false); err != nil {
				logrus.WithError(err).Error("restore thermal adapter before shutdown")
			}
		}
		return
	}
	if capabilities.ChargingControl {
		if err := smcConn.ResetChargeControl(); err != nil {
			logrus.WithError(err).Error("failed to reset charge control before exiting")
		}
	}
	if capabilities.AdapterControl {
		if err := smcConn.EnableAdapter(); err != nil {
			logrus.WithError(err).Error("failed to re-enable adapter before exiting")
		}
	}
}
