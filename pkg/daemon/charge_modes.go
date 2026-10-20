package daemon

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/sirupsen/logrus"
)

// Sailing and Top Up ride on the charge hold, so they need native mode with
// charge-hold support.
func requireChargeHold(c *gin.Context) bool {
	if heatHold == nil {
		c.AbortWithStatusJSON(http.StatusConflict, "This needs charge-hold support (Apple Silicon on macOS 27)")
		return false
	}
	return true
}

func reconcileChargeHold() {
	heatHold.reconcile(conf.HeatProtectionEnabled(), conf.HeatPauseTemperatureCelsius(), conf.HeatResumeTemperatureCelsius())
}

// setSailing sets how far the charge may drift below the limit before it
// charges again: 0 (off) to 20 points.
func setSailing(c *gin.Context) {
	if !requireChargeHold(c) {
		return
	}
	var level int
	if err := c.BindJSON(&level); err != nil {
		c.AbortWithStatusJSON(http.StatusBadRequest, err.Error())
		return
	}
	if level < 0 || level > 20 {
		c.AbortWithStatusJSON(http.StatusBadRequest, "Sailing level must be between 0 and 20")
		return
	}
	maintainLoopInnerLock.Lock()
	defer maintainLoopInnerLock.Unlock()
	old := conf.SailingLevel()
	conf.SetSailingLevel(level)
	if err := conf.Save(); err != nil {
		conf.SetSailingLevel(old)
		c.AbortWithStatusJSON(http.StatusInternalServerError, err.Error())
		return
	}
	reconcileChargeHold()
	logrus.WithField("level", level).Info("sailing level set")
	c.IndentedJSON(http.StatusCreated, "Sailing updated")
}

// setTopUp charges to 100% until the adapter is disconnected, then restores
// the previous Apple limit. It suspends Sailing and any custom limit.
func setTopUp(c *gin.Context) {
	if !requireChargeHold(c) {
		return
	}
	var enabled bool
	if err := c.BindJSON(&enabled); err != nil {
		c.AbortWithStatusJSON(http.StatusBadRequest, err.Error())
		return
	}
	maintainLoopInnerLock.Lock()
	defer maintainLoopInnerLock.Unlock()
	if !enabled {
		if conf.TopUpActive() {
			heatHold.endTopUp(conf.TopUpRestoreLimit())
		}
		reconcileChargeHold()
		c.IndentedJSON(http.StatusCreated, "Top Up stopped")
		return
	}
	if !conf.TopUpActive() {
		restore := 80
		if conf.CustomChargeLimit() == 0 {
			limit, err := heatHold.effectiveAppleLimit(heatHold.holder.Active())
			if err != nil {
				c.AbortWithStatusJSON(http.StatusServiceUnavailable, err.Error())
				return
			}
			if limit < 100 {
				restore = limit
			}
		}
		conf.SetTopUp(true, restore)
		if err := conf.Save(); err != nil {
			conf.SetTopUp(false, 0)
			c.AbortWithStatusJSON(http.StatusInternalServerError, err.Error())
			return
		}
		if heatHold.holder.Active() {
			heatHold.pendingLimit = 100
		} else if err := heatHold.setLimit(100); err != nil {
			heatHold.endTopUp(restore)
			c.AbortWithStatusJSON(http.StatusServiceUnavailable, err.Error())
			return
		}
	}
	reconcileChargeHold()
	if !conf.TopUpActive() {
		c.AbortWithStatusJSON(http.StatusConflict, "Top Up needs the charger connected")
		return
	}
	logrus.Info("Top Up started")
	c.IndentedJSON(http.StatusCreated, "Top Up started")
}
