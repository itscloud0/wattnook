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

func setNativeLimit(c *gin.Context, limit int) {
	if !slices.Contains(capabilities.SupportedLimits, limit) {
		c.AbortWithStatusJSON(http.StatusBadRequest, "Choose one of the supported Apple charge limits")
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
