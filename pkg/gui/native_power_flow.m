#import "native_internal.h"
#import <QuartzCore/QuartzCore.h>

static void Text(NSString *value, NSRect rect, CGFloat size, NSFontWeight weight,
                 NSColor *color, NSTextAlignment alignment) {
    NSDictionary *style = @{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color,
    };
    NSSize measured = [value sizeWithAttributes:style];
    CGFloat x = NSMinX(rect);
    if (alignment == NSTextAlignmentCenter) x = NSMidX(rect) - measured.width / 2;
    if (alignment == NSTextAlignmentRight) x = NSMaxX(rect) - measured.width;
    [value drawAtPoint:NSMakePoint(x, NSMidY(rect) - measured.height / 2)
      withAttributes:style];
}

static void Symbol(NSString *name, NSRect rect, CGFloat size, NSColor *color) {
    NSImage *source = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (source == nil) return;
    source = [source imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightRegular]];
    NSSize intrinsic = source.size;
    if (intrinsic.width <= 0 || intrinsic.height <= 0) return;
    CGFloat scale = MIN(NSWidth(rect) / intrinsic.width, NSHeight(rect) / intrinsic.height);
    NSSize fitted = NSMakeSize(intrinsic.width * scale, intrinsic.height * scale);
    NSRect target = NSMakeRect(NSMidX(rect) - fitted.width / 2,
                               NSMidY(rect) - fitted.height / 2,
                               fitted.width, fitted.height);
    NSImage *tinted = [[[NSImage alloc] initWithSize:fitted] autorelease];
    [tinted lockFocus];
    [source drawInRect:NSMakeRect(0, 0, fitted.width, fitted.height)
             fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [color setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, fitted.width, fitted.height),
                             NSCompositingOperationSourceAtop);
    [tinted unlockFocus];
    [tinted drawInRect:target fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1];
}



// A single straight stream of constant thickness between two nodes.

// Two streams stacked into one trunk at the shared node, splitting to (or
// merging from) the upper and lower nodes. The trunk gets a single round
// end, so the split reads as one stream dividing.

static void ReadingLine(NSString *name, NSString *value, NSColor *color, NSRect rect, NSColor *muted) {
    NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:[name stringByAppendingString:@"  "]
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                     NSForegroundColorAttributeName:muted}] autorelease];
    [text appendAttributedString:[[[NSAttributedString alloc] initWithString:value
        attributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium],
                     NSForegroundColorAttributeName:color}] autorelease]];
    NSSize measured = text.size;
    [text drawAtPoint:NSMakePoint(NSMaxX(rect) - measured.width, NSMidY(rect) - measured.height / 2)];
}

static void TemperatureLine(NSString *name, double celsius, NSColor *color, NSRect rect, NSColor *muted) {
    NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:[name stringByAppendingString:@"  "]
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                     NSForegroundColorAttributeName:muted}] autorelease];
    [text appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%.0f°C", celsius]
        attributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium],
                     NSForegroundColorAttributeName:color}] autorelease]];
    NSSize measured = text.size;
    [text drawAtPoint:NSMakePoint(NSMaxX(rect) - measured.width, NSMidY(rect) - measured.height / 2)];
}




@implementation BattPowerFlowView {
    NSInteger _previewLimitPercent;
    BOOL _limitDragging;
    // The focus ring is for keyboard users; a click or the popover opening
    // makes the rail first responder without asking for a ring.
    BOOL _keyboardFocus;
    NSRect _healthTipRect;
    double _macSamples[90];
    unsigned char _sampleStates[90];
    NSInteger _sampleCount;
    NSTimeInterval _lastSample;
    BOOL _limitMoved;
    NSPoint _limitDragStart;
    CAGradientLayer *_flowHighlight;
}

- (void)dealloc { [_supportedLimits release]; [_flowHighlight release]; [super dealloc]; }
- (void)setFlowAnimationEnabled:(BOOL)enabled {
    _flowAnimationEnabled = enabled && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (!_flowAnimationEnabled) [_flowHighlight removeAllAnimations];
    _flowHighlight.hidden = !_flowAnimationEnabled;
    [self setNeedsDisplay:YES];
}
- (void)updateAnimationMask:(NSBezierPath *)path {
    if (!_flowAnimationEnabled || !self.window.visible || self.hiddenOrHasHiddenAncestor ||
        path.elementCount == 0 || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        [_flowHighlight removeAllAnimations]; _flowHighlight.hidden = YES; return;
    }
    self.wantsLayer = YES;
    if (!_flowHighlight) {
        _flowHighlight = [[CAGradientLayer alloc] init];
        _flowHighlight.colors = @[(id)NSColor.clearColor.CGColor,
            (id)[NSColor.whiteColor colorWithAlphaComponent:0.20].CGColor,
            (id)NSColor.clearColor.CGColor];
        _flowHighlight.startPoint = CGPointMake(0, 0.5);
        _flowHighlight.endPoint = CGPointMake(1, 0.5);
        _flowHighlight.locations = @[@0, @0.10, @0.20];
        [self.layer addSublayer:_flowHighlight];
    }
    CGMutablePathRef mask = CGPathCreateMutable();
    for (NSInteger i=0; i<path.elementCount; i++) {
        NSPoint points[3];
        switch ([path elementAtIndex:i associatedPoints:points]) {
            case NSBezierPathElementMoveTo: CGPathMoveToPoint(mask,NULL,points[0].x,points[0].y); break;
            case NSBezierPathElementLineTo: CGPathAddLineToPoint(mask,NULL,points[0].x,points[0].y); break;
            case NSBezierPathElementCurveTo: CGPathAddCurveToPoint(mask,NULL,points[0].x,points[0].y,
                points[1].x,points[1].y,points[2].x,points[2].y); break;
            case NSBezierPathElementClosePath: CGPathCloseSubpath(mask); break;
            default: break; // These authored paths contain only cubic curves.
        }
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _flowHighlight.frame = self.bounds;
    CAShapeLayer *shape = [CAShapeLayer layer]; shape.frame = self.bounds; shape.path = mask;
    _flowHighlight.mask = shape; _flowHighlight.hidden = NO;
    [CATransaction commit]; CGPathRelease(mask);
    if (![_flowHighlight animationForKey:@"flow"]) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"locations"];
        animation.fromValue = @[@-0.2, @-0.1, @0];
        animation.toValue = @[@1, @1.1, @1.2];
        animation.duration = 3.2; animation.repeatCount = HUGE_VALF;
        [_flowHighlight addAnimation:animation forKey:@"flow"];
    }
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _chargePercent = -1;
        _cycleCount = -1;
        _limitPercent = 80;
        _previewLimitPercent = 80;
    }
    return self;
}

- (void)setLimitPercent:(NSInteger)limitPercent {
    _limitPercent = limitPercent < 0 ? -1 : MAX(0, MIN(100, limitPercent));
    if (!_limitDragging) _previewLimitPercent = _limitPercent;
    [self setNeedsDisplay:YES];
    [self.window invalidateCursorRectsForView:self];
}

- (NSInteger)displayedLimitPercent {
    return _previewLimitPercent;
}

- (NSRect)railRect {
    // 32 pt: the content edge inside the 16 pt tiles, on the 8 pt grid.
    return NSMakeRect(32, 163, NSWidth(self.bounds) - 64, 6);
}

- (CGFloat)markerX {
    NSRect rail = [self railRect];
    return NSMinX(rail) + NSWidth(rail) * self.displayedLimitPercent / 100.0;
}

- (NSInteger)limitForPoint:(NSPoint)point {
    NSRect rail = [self railRect];
    double fraction = (point.x - NSMinX(rail)) / NSWidth(rail);
    NSInteger value = (NSInteger)round(fraction * 100.0 / 5.0) * 5;
    // 100% disables charging control; keep that explicit in the existing menu.
    return [self snappedLimit:value];
}

- (NSInteger)snappedLimit:(NSInteger)value {
    if (!self.supportedLimits.count) return MAX(20, MIN(95, value));
    NSInteger closest = self.supportedLimits.firstObject.integerValue;
    for (NSNumber *choice in self.supportedLimits)
        if (labs(choice.integerValue-value) < labs(closest-value)) closest = choice.integerValue;
    return closest;
}

- (void)updatePreviewWithEvent:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _previewLimitPercent = [self limitForPoint:point];
    [self setNeedsDisplay:YES];
    [self.window invalidateCursorRectsForView:self];
}

- (void)commitPreview {
    if (_previewLimitPercent != _limitPercent) {
        [NSApp sendAction:self.limitAction to:self.limitTarget from:self];
    } else {
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!self.limitEditable || fabs(point.x - [self markerX]) > 16 ||
        fabs(point.y - NSMidY([self railRect])) > 16) {
        [super mouseDown:event];
        return;
    }
    _limitDragging = YES;
    _limitMoved = NO;
    _limitDragStart = point;
    _keyboardFocus = NO;
    [self.window makeFirstResponder:self];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_limitDragging) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (fabs(point.x - _limitDragStart.x) < 3 && !_limitMoved) return;
    _limitMoved = YES;
    [self updatePreviewWithEvent:event];
}

- (void)mouseUp:(NSEvent *)event {
    if (!_limitDragging) return;
    if (_limitMoved) [self updatePreviewWithEvent:event];
    _limitDragging = NO;
    if (_limitMoved) [self commitPreview];
}

- (void)recordMacWatts:(double)watts charging:(BOOL)charging heat:(BOOL)heat onBattery:(BOOL)onBattery {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!isfinite(watts) || watts < 0 || (_sampleCount && now - _lastSample < 10)) return;
    _lastSample = now;
    if (_sampleCount == 90) {
        memmove(_macSamples, _macSamples + 1, sizeof(double) * 89);
        memmove(_sampleStates, _sampleStates + 1, 89);
        _sampleCount = 89;
    }
    _macSamples[_sampleCount] = watts;
    _sampleStates[_sampleCount] = heat ? 2 : (charging ? 1 : (onBattery ? 3 : 0));
    _sampleCount++;
    self.stripView.needsDisplay = YES;
}
- (NSInteger)powerSampleCount { return _sampleCount; }
- (double)powerSampleAt:(NSInteger)index state:(NSInteger *)state {
    if (index < 0 || index >= _sampleCount) return NAN;
    if (state) *state = _sampleStates[index];
    return _macSamples[index];
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)view; (void)tag; (void)point; (void)data;
    NSString *cycles = self.cycleCount >= 0 ?
        [NSString stringWithFormat:@", %ld charge cycles", (long)self.cycleCount] : @"";
    return [NSString stringWithFormat:@"Full-charge capacity is %ld%% of the design capacity%@",
        (long)self.healthPercent, cycles];
}

- (BOOL)acceptsFirstResponder {
    return self.limitEditable;
}
- (BOOL)becomeFirstResponder {
    _keyboardFocus = NSApp.currentEvent.type == NSEventTypeKeyDown;
    [self setNeedsDisplay:YES];
    return [super becomeFirstResponder];
}
- (BOOL)resignFirstResponder { [self setNeedsDisplay:YES]; return [super resignFirstResponder]; }

- (void)keyDown:(NSEvent *)event {
    if (self.limitEditable && (event.keyCode == 123 || event.keyCode == 124)) {
        NSInteger direction = event.keyCode == 123 ? -5 : 5;
        _previewLimitPercent = [self snappedLimit:self.displayedLimitPercent + direction];
        [self commitPreview];
        return;
    }
    [super keyDown:event];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.limitEditable) {
        [self addCursorRect:NSMakeRect([self markerX] - 16, 119, 32, 30)
                    cursor:NSCursor.openHandCursor];
    }
}

- (BOOL)isAccessibilityElement { return self.limitEditable; }
- (NSString *)accessibilityRole { return NSAccessibilitySliderRole; }
- (NSString *)accessibilityLabel { return @"Charge limit"; }
- (id)accessibilityValue { return @(self.displayedLimitPercent); }
- (id)accessibilityMinValue { return self.supportedLimits.firstObject ?: @20; }
- (id)accessibilityMaxValue { return self.supportedLimits.lastObject ?: @95; }
- (void)accessibilitySetValue:(id)value {
    if (!self.limitEditable || ![value respondsToSelector:@selector(integerValue)]) return;
    _previewLimitPercent = [self snappedLimit:(NSInteger)round([value doubleValue] / 5.0) * 5];
    [self commitPreview];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat width = NSWidth(self.bounds);
    CGFloat right = width - 32;
    BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    NSInteger charge = MAX(0, MIN(100, self.chargePercent));
    NSInteger limit = self.displayedLimitPercent;
    // A connected charger the Mac isn't drawing from still reads ~0.4 W
    // (charger electronics); below 1 W it is not powering the Mac.
    BOOL adapter = self.hasTelemetry && self.pluggedIn && self.adapterWatts > 1.0;
    BOOL charging = self.hasTelemetry && self.batteryWatts > 0.25;
    BOOL statusCharging = self.chargingStateKnown ? self.batteryCharging : charging;
    // On adapter power a held battery reads a few hundred mW either way;
    // don't present that noise as the battery helping power the Mac.
    BOOL discharging = self.hasTelemetry && self.batteryWatts < (self.pluggedIn ? -0.75 : -0.25);
    BOOL hybrid = adapter && discharging;
    BOOL atLimit = adapter && !charging && !discharging &&
        limit >= 0 && limit < 100 && self.chargePercent >= limit - 1;
    NSString *state = !self.hasTelemetry ? @"Power data unavailable" :
        (hybrid && !self.dischargingToLimit ? @"AC + battery" :
         (self.heatPaused && self.pluggedIn ? @"Paused while the battery cools" :
         (self.topUpActive && self.pluggedIn ? @"Topping up to 100%" :
         (self.dischargingToLimit && self.pluggedIn && limit > 0 ?
            [NSString stringWithFormat:@"Discharging to %ld%%", (long)limit] :
         (self.sailing && self.pluggedIn && limit > 0 ?
            [NSString stringWithFormat:@"Sailing, charges again at %ld%%", (long)MAX(0, limit - self.sailingLevel)] :
          (statusCharging ? @"Charging" :
           (atLimit ? @"Charge limit reached" : (adapter ? @"Plugged in" : @"On battery"))))))));
    NSString *chargeText = self.chargePercent < 0 ? @"—%" :
        [NSString stringWithFormat:@"%ld%%", (long)charge];

    // One light numeral; the percent sign is small and muted beside it.
    (void)chargeText;
    NSMutableAttributedString *chargeLine = [[[NSMutableAttributedString alloc]
        initWithString:self.chargePercent < 0 ? @"—" : [NSString stringWithFormat:@"%ld", (long)charge]
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:66 weight:NSFontWeightLight],
                         NSForegroundColorAttributeName:NSColor.labelColor}] autorelease];
    [chargeLine addAttribute:NSKernAttributeName value:@3 range:NSMakeRange(chargeLine.length - 1, 1)];
    [chargeLine appendAttributedString:[[[NSAttributedString alloc] initWithString:@"%"
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:26 weight:NSFontWeightLight],
                     NSForegroundColorAttributeName:NSColor.secondaryLabelColor}] autorelease]];
    [chargeLine drawAtPoint:NSMakePoint(29, 224 - chargeLine.size.height / 2)];
    // Orange marks the heat pause on the state line only; green marks charging.
    Text(state, NSMakeRect(32, 174, 230, 18), 13, NSFontWeightRegular,
         self.heatPaused && self.pluggedIn ? WattWarningColor() :
         (statusCharging ? NSColor.systemGreenColor : NSColor.secondaryLabelColor),
         NSTextAlignmentLeft);
    // Battery and processor temperatures side by side: Heat Protection acts
    // on the battery, while a hot fanless Mac is usually the processor.
    // Battery health joins them, as CleanMyMac's battery card does: the
    // capacity left against the design capacity, with the cycle count.
    NSColor *headerMuted = NSColor.secondaryLabelColor;
    BOOL showCPU = self.processorTemperatureCelsius > 0;
    BOOL showHealth = self.healthPercent > 0;
    NSInteger lines = (self.temperatureCelsius > 0) + showCPU + showHealth;
    CGFloat lineY = lines >= 3 ? 236 : (lines == 2 ? 226 : 216);
    if (self.temperatureCelsius > 0) {
        TemperatureLine(@"Battery", self.temperatureCelsius, NSColor.labelColor,
            NSMakeRect(right - 146, lineY, 146, 20), headerMuted);
        lineY -= lines >= 3 ? 20 : 22;
    }
    if (showCPU) {
        NSColor *color = self.processorTemperatureCelsius >= 85 ? WattWarningColor() : NSColor.labelColor;
        TemperatureLine(@"CPU", self.processorTemperatureCelsius, color,
            NSMakeRect(right - 146, lineY, 146, 20), headerMuted);
        lineY -= lines >= 3 ? 20 : 22;
    }
    if (showHealth) {
        // Apple calls under 80% "Service Recommended"; only then is it a warning.
        NSColor *color = self.healthPercent < 80 ? WattWarningColor() : NSColor.labelColor;
        NSRect healthRect = NSMakeRect(right - 146, lineY, 146, 20);
        ReadingLine(@"Health", [NSString stringWithFormat:@"%ld%%", (long)self.healthPercent], color,
            healthRect, headerMuted);
        if (!NSEqualRects(healthRect, _healthTipRect)) {
            [self removeAllToolTips];
            [self addToolTipRect:healthRect owner:self userData:NULL];
            _healthTipRect = healthRect;
        }
    }

    NSRect rail = [self railRect];
    NSColor *trackColor = dark ? [NSColor.whiteColor colorWithAlphaComponent:0.13] :
        [NSColor.blackColor colorWithAlphaComponent:0.14];
    [trackColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rail xRadius:3 yRadius:3] fill];
    if (self.chargePercent >= 0 && charge > 0) {
        NSColor *fillColor = statusCharging ? NSColor.systemGreenColor :
            (charge <= 20 ? WattWarningColor() : WattAccentColor());
        [fillColor setFill];
        NSRect fill = rail;
        fill.size.width = MAX(6, rail.size.width * charge / 100.0);
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:3 yRadius:3] fill];
    }
    CGFloat markerX = [self markerX];
    if (limit >= 0 && self.limitEditable) {
        // A raised grip says "drag me"; the bare tick only marks a read-only limit.
        // 16 pt tall: clear of the state line above the rail.
        NSRect grip = NSMakeRect(markerX - 3, NSMidY(rail) - 8, 6, 16);
        NSBezierPath *gripPath = [NSBezierPath bezierPathWithRoundedRect:grip xRadius:3 yRadius:3];
        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow = [[[NSShadow alloc] init] autorelease];
        shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.35];
        shadow.shadowOffset = NSMakeSize(0, -1); shadow.shadowBlurRadius = 3; [shadow set];
        [[NSColor colorWithCalibratedWhite:0.96 alpha:1] setFill]; [gripPath fill];
        [NSGraphicsContext restoreGraphicsState];
        if (self.window.firstResponder == self && _keyboardFocus) {
            NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(grip, -3, -3) xRadius:5 yRadius:5];
            ring.lineWidth = 2; [NSColor.keyboardFocusIndicatorColor setStroke]; [ring stroke];
        }
    } else if (limit >= 0) {
        [NSColor.labelColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(markerX - 1.5, 158, 3, 16) xRadius:2 yRadius:2] fill];
    }
    // The controller's non-interactive label never intercepts marker dragging.

    if (!self.hasTelemetry) {
        [self updateAnimationMask:[NSBezierPath bezierPath]];
        Text(@"Power flow unavailable", NSMakeRect(20, 42, width - 40, 40),
             12, NSFontWeightMedium, NSColor.secondaryLabelColor, NSTextAlignmentCenter);
        return;
    }

    // IOKit can briefly report battery charging power above adapter input.
    // Its derived system power is then clamped to zero; don't draw that as fact.
    if (charging && (!self.pluggedIn || self.adapterWatts < self.batteryWatts + 0.5 ||
                     self.systemWatts < 0.5)) {
        [self updateAnimationMask:[NSBezierPath bezierPath]];
        Text(@"Power readings updating", NSMakeRect(20, 64, width - 40, 20),
             12, NSFontWeightMedium, NSColor.labelColor, NSTextAlignmentCenter);
        Text(@"Adapter and battery data disagree", NSMakeRect(20, 42, width - 40, 18),
             10, NSFontWeightRegular, NSColor.secondaryLabelColor, NSTextAlignmentCenter);
        return;
    }

    // AlDente's flow, read from its four reference states: one silhouette whose
    // outer corners alone are rounded, end blocks split from the bands by a
    // 4 pt groove, neutral bands as thick as their watts with the watts inside,
    // colour only when the battery helps an adapter that can't keep up.
    (void)dark;
    BOOL fromBattery = !adapter;
    NSInteger level = self.chargePercent < 0 ? 100 : self.chargePercent;
    NSString *battery = charging ? @"battery.100percent.bolt" :
        (level >= 88 ? @"battery.100percent" : level >= 63 ? @"battery.75percent" :
         level >= 38 ? @"battery.50percent" : level >= 13 ? @"battery.25percent" : @"battery.0percent");
    const CGFloat top = 124, nodeW = 52, groove = 4, split = 6, radius = 14;
    CGFloat leftX = 16, rightX = width - 16 - nodeW, bandL = leftX + nodeW + groove, bandR = rightX - groove;
    NSColor *nodeColor = WattTileColor(NO);
    NSColor *bandColor = [NSColor colorWithSRGBRed:0x34/255.0 green:0x34/255.0 blue:0x37/255.0 alpha:1];
    NSBezierPath *mask = [NSBezierPath bezierPath];
    // Only the corners on the diagram's outside are rounded.
    NSBezierPath *(^block)(NSRect, BOOL, BOOL, BOOL) = ^(NSRect r, BOOL outerLeft, BOOL roundTop, BOOL roundBottom) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        CGFloat x0 = NSMinX(r), x1 = NSMaxX(r), y0 = NSMinY(r), y1 = NSMaxY(r);
        CGFloat tl = outerLeft && roundTop ? radius : 0, bl = outerLeft && roundBottom ? radius : 0;
        CGFloat tr = !outerLeft && roundTop ? radius : 0, br = !outerLeft && roundBottom ? radius : 0;
        [path moveToPoint:NSMakePoint(x0 + bl, y0)];
        [path lineToPoint:NSMakePoint(x1 - br, y0)];
        if (br) [path appendBezierPathWithArcFromPoint:NSMakePoint(x1, y0) toPoint:NSMakePoint(x1, y0 + br) radius:br];
        [path lineToPoint:NSMakePoint(x1, y1 - tr)];
        if (tr) [path appendBezierPathWithArcFromPoint:NSMakePoint(x1, y1) toPoint:NSMakePoint(x1 - tr, y1) radius:tr];
        [path lineToPoint:NSMakePoint(x0 + tl, y1)];
        if (tl) [path appendBezierPathWithArcFromPoint:NSMakePoint(x0, y1) toPoint:NSMakePoint(x0, y1 - tl) radius:tl];
        [path lineToPoint:NSMakePoint(x0, y0 + bl)];
        if (bl) [path appendBezierPathWithArcFromPoint:NSMakePoint(x0, y0) toPoint:NSMakePoint(x0 + bl, y0) radius:bl];
        [path closePath];
        return path;
    };
    NSBezierPath *(^band)(CGFloat, CGFloat, CGFloat, CGFloat) = ^(CGFloat l0, CGFloat l1, CGFloat r0, CGFloat r1) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        CGFloat k = (bandR - bandL) * 0.5;
        [path moveToPoint:NSMakePoint(bandL, l1)];
        [path curveToPoint:NSMakePoint(bandR, r1) controlPoint1:NSMakePoint(bandL + k, l1) controlPoint2:NSMakePoint(bandR - k, r1)];
        [path lineToPoint:NSMakePoint(bandR, r0)];
        [path curveToPoint:NSMakePoint(bandL, l0) controlPoint1:NSMakePoint(bandR - k, r0) controlPoint2:NSMakePoint(bandL + k, l0)];
        [path closePath];
        return path;
    };
    // An end block: grey, its icon, and the total when it is the single side.
    void (^node)(NSRect, BOOL, BOOL, BOOL, NSString *, NSColor *, NSString *) =
        ^(NSRect r, BOOL outerLeft, BOOL roundTop, BOOL roundBottom, NSString *icon, NSColor *tint, NSString *value) {
        [nodeColor setFill]; [block(r, outerLeft, roundTop, roundBottom) fill];
        CGFloat iconY = value ? NSMidY(r) + 1 : NSMidY(r) - 11;
        Symbol(icon, NSMakeRect(NSMidX(r) - 14, iconY, 28, 22), 18, tint);
        if (value) Text(value, NSMakeRect(NSMinX(r), NSMidY(r) - 21, NSWidth(r), 18), 13,
                        NSFontWeightMedium, NSColor.labelColor, NSTextAlignmentCenter);
    };
    void (^fillBand)(NSBezierPath *, BOOL) = ^(NSBezierPath *path, BOOL towardsMac) {
        if (towardsMac) {
            // The weak-adapter case: neutral fading into the accent at the Mac.
            NSGradient *g = [[[NSGradient alloc] initWithStartingColor:bandColor
                endingColor:[WattAccentColor() colorWithAlphaComponent:0.75]] autorelease];
            [g drawInBezierPath:path angle:0];
        } else {
            [bandColor setFill]; [path fill];
        }
    };
    void (^label)(double, CGFloat, CGFloat) = ^(double watts, CGFloat y0, CGFloat y1) {
        if (y1 - y0 < 18) return;
        Text([NSString stringWithFormat:@"%.2f W", watts], NSMakeRect(bandL, (y0 + y1) / 2 - 9, bandR - bandL, 18),
             14, NSFontWeightSemibold, NSColor.labelColor, NSTextAlignmentCenter);
    };
    NSString *(^total)(double) = ^NSString *(double w) { return [NSString stringWithFormat:@"%.0fW", MAX(0, w)]; };
    NSColor *macTint = WattAccentColor();
    if ((adapter && charging) || hybrid) {
        double a = adapter && charging ? self.batteryWatts : self.adapterWatts;   // upper stream
        double b = adapter && charging ? self.systemWatts : -self.batteryWatts;   // lower stream
        double sum = MAX(0.1, a + b);
        CGFloat usable = top - split, upper = MAX(40, MIN(usable - 40, usable * a / sum));
        NSRect upperNode = NSMakeRect(0, top - upper, nodeW, upper), lowerNode = NSMakeRect(0, 0, nodeW, usable - upper);
        CGFloat seam = top * b / sum;
        NSBezierPath *upperBand, *lowerBand;
        if (adapter && charging) {
            upperNode.origin.x = lowerNode.origin.x = rightX;
            upperBand = band(seam, top, NSMinY(upperNode), NSMaxY(upperNode));
            lowerBand = band(0, seam, NSMinY(lowerNode), NSMaxY(lowerNode));
            node(NSMakeRect(leftX, 0, nodeW, top), YES, YES, YES, @"bolt.fill", NSColor.labelColor, total(self.adapterWatts));
            node(upperNode, NO, YES, YES, battery, NSColor.labelColor, nil);
            node(lowerNode, NO, YES, YES, @"laptopcomputer", macTint, nil);
            fillBand(upperBand, NO); fillBand(lowerBand, NO);
        } else {
            upperNode.origin.x = lowerNode.origin.x = leftX;
            upperBand = band(NSMinY(upperNode), NSMaxY(upperNode), seam, top);
            lowerBand = band(NSMinY(lowerNode), NSMaxY(lowerNode), 0, seam);
            node(upperNode, YES, YES, YES, @"bolt.fill", NSColor.labelColor, nil);
            node(lowerNode, YES, YES, YES, battery, NSColor.labelColor, nil);
            node(NSMakeRect(rightX, 0, nodeW, top), NO, YES, YES, @"laptopcomputer", macTint, total(self.systemWatts));
            fillBand(upperBand, YES); fillBand(lowerBand, YES);
        }
        [mask appendBezierPath:upperBand]; [mask appendBezierPath:lowerBand];
        label(a, NSMinY(upperNode), NSMaxY(upperNode));
        label(b, NSMinY(lowerNode), NSMaxY(lowerNode));
    } else {
        double w = fromBattery ? -self.batteryWatts : self.adapterWatts;
        node(NSMakeRect(leftX, 0, nodeW, top), YES, YES, YES, fromBattery ? battery : @"bolt.fill", NSColor.labelColor, nil);
        node(NSMakeRect(rightX, 0, nodeW, top), NO, YES, YES, @"laptopcomputer", macTint, nil);
        NSBezierPath *only = band(0, top, 0, top);
        fillBand(only, NO);
        if (w > 0.25) [mask appendBezierPath:only];
        Text(w > 0.25 ? [NSString stringWithFormat:@"%.2f W", w] : @"Waiting for a reading",
             NSMakeRect(bandL, top / 2 - 9, bandR - bandL, 18), 14, NSFontWeightSemibold,
             w > 0.25 ? NSColor.labelColor : NSColor.secondaryLabelColor, NSTextAlignmentCenter);
    }
    [self updateAnimationMask:mask];
}

@end


// An hourly-forecast strip for power: one bar per 10 s of Mac draw, coloured
// by what the battery was doing (green charging, orange heat pause, grey held
// or on battery). Empty slots stay as a faint baseline, never invented bars.
@implementation WattPowerStripView
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    BattPowerFlowView *flow = self.source;
    NSInteger count = flow.powerSampleCount;
    NSColor *muted = [NSColor.whiteColor colorWithAlphaComponent:0.68];
    CGFloat width = NSWidth(self.bounds);
    double peak = 0, sum = 0;
    for (NSInteger i = 0; i < count; i++) { double w = [flow powerSampleAt:i state:NULL]; peak = MAX(peak, w); sum += w; }
    NSDictionary *label = @{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName:muted};
    [@"Last 15 minutes" drawAtPoint:NSMakePoint(0, NSHeight(self.bounds) - 15) withAttributes:label];
    NSString *summary = count ? [NSString stringWithFormat:@"Avg %.1f W    Peak %.1f W", sum / count, peak] :
        @"First bar in 10 s";
    NSDictionary *figure = @{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
                             NSForegroundColorAttributeName:NSColor.whiteColor};
    NSSize size = [summary sizeWithAttributes:figure];
    [summary drawAtPoint:NSMakePoint(width - size.width, NSHeight(self.bounds) - 15) withAttributes:figure];
    CGFloat chartHeight = NSHeight(self.bounds) - 22, slot = width / 90.0, bar = MAX(1.5, slot - 1.2);
    double scale = MAX(peak, 5);
    for (NSInteger i = 0; i < 90; i++) {
        NSInteger sample = i - (90 - count);
        CGFloat x = i * slot;
        if (sample < 0) {
            [[NSColor.whiteColor colorWithAlphaComponent:0.10] setFill];
            NSRectFill(NSMakeRect(x, 0, bar, 2));
            continue;
        }
        NSInteger state = 0;
        double w = [flow powerSampleAt:sample state:&state];
        NSColor *color = state == 1 ? NSColor.systemGreenColor : state == 2 ? WattWarningColor() :
            [NSColor.whiteColor colorWithAlphaComponent:0.78];
        [color setFill];
        CGFloat h = MAX(2, chartHeight * w / scale);
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, 0, bar, h) xRadius:MIN(1, bar / 2) yRadius:MIN(1, bar / 2)] fill];
    }
}
- (NSString *)accessibilityLabel {
    return @"Mac power over the last 15 minutes";
}
@end
