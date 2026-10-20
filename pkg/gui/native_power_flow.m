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

static void FlowNode(NSString *symbol, NSRect rect, NSColor *symbolColor, BOOL dark) {
    NSColor *surface = dark ? [NSColor.whiteColor colorWithAlphaComponent:0.10] :
        [NSColor.blackColor colorWithAlphaComponent:0.07];
    [surface setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:8 yRadius:8] fill];
    Symbol(symbol, NSInsetRect(rect, 7, 7), 19, symbolColor);
}

static NSColor *FlowColor(void) {
    return WattAccentColor();
}

// Sankey-style bands: constant thickness per stream (thickness encodes
// watts), round ends that stop just short of the nodes, straight lead-ins
// and one smooth S-curve between.
static const CGFloat FlowNodeGap = 4;

static NSBezierPath *Band(CGFloat x0, CGFloat sourceTop, CGFloat sourceBottom,
                          CGFloat x1, CGFloat targetTop, CGFloat targetBottom,
                          BOOL capStart, BOOL capEnd) {
    CGFloat sr = (sourceTop - sourceBottom) / 2, tr = (targetTop - targetBottom) / 2;
    if (capStart) x0 += sr;
    if (capEnd) x1 -= tr;
    CGFloat lead = 10, xs = x0 + lead, xe = x1 - lead, k = (xe - xs) * 0.5;
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(x0, sourceTop)];
    [path lineToPoint:NSMakePoint(xs, sourceTop)];
    [path curveToPoint:NSMakePoint(xe, targetTop)
         controlPoint1:NSMakePoint(xs + k, sourceTop) controlPoint2:NSMakePoint(xe - k, targetTop)];
    [path lineToPoint:NSMakePoint(x1, targetTop)];
    if (capEnd) [path appendBezierPathWithArcWithCenter:NSMakePoint(x1, targetTop - tr)
        radius:tr startAngle:90 endAngle:-90 clockwise:YES];
    else [path lineToPoint:NSMakePoint(x1, targetBottom)];
    [path lineToPoint:NSMakePoint(xe, targetBottom)];
    [path curveToPoint:NSMakePoint(xs, sourceBottom)
         controlPoint1:NSMakePoint(xe - k, targetBottom) controlPoint2:NSMakePoint(xs + k, sourceBottom)];
    [path lineToPoint:NSMakePoint(x0, sourceBottom)];
    if (capStart) [path appendBezierPathWithArcWithCenter:NSMakePoint(x0, sourceBottom + sr)
        radius:sr startAngle:-90 endAngle:90 clockwise:YES];
    [path closePath];
    return path;
}

static void FillFlow(NSBezierPath *path) {
    [FlowColor() setFill];
    [path fill];
}

// A single straight stream of constant thickness between two nodes.
static NSBezierPath *Flow(CGFloat x0, CGFloat y0, CGFloat x1, CGFloat y1,
                          CGFloat startWidth, CGFloat endWidth) {
    (void)endWidth;
    NSBezierPath *path = Band(x0 + FlowNodeGap, y0 + startWidth / 2, y0 - startWidth / 2,
                              x1 - FlowNodeGap, y1 + startWidth / 2, y1 - startWidth / 2, YES, YES);
    FillFlow(path);
    return path;
}

// Two streams stacked into one trunk at the shared node, splitting to (or
// merging from) the upper and lower nodes. The trunk gets a single round
// end, so the split reads as one stream dividing.
static NSBezierPath *Fork(CGFloat x0, CGFloat x1, CGFloat upperWidth,
                          CGFloat lowerWidth, BOOL merge) {
    CGFloat center = 49, radius = (upperWidth + lowerWidth) / 2, top = center + radius;
    CGFloat trunk = x0 + FlowNodeGap + radius;
    // The upper band overlaps the lower by a hair so antialiasing leaves no seam.
    NSBezierPath *upper = Band(trunk, top, top - upperWidth - 0.6,
                               x1 - FlowNodeGap, 70 + upperWidth / 2, 70 - upperWidth / 2, NO, YES);
    NSBezierPath *lower = Band(trunk, top - upperWidth, top - upperWidth - lowerWidth,
                               x1 - FlowNodeGap, 28 + lowerWidth / 2, 28 - lowerWidth / 2, NO, YES);
    NSBezierPath *cap = [NSBezierPath bezierPath];
    [cap moveToPoint:NSMakePoint(trunk + 1, center + radius)];
    [cap appendBezierPathWithArcWithCenter:NSMakePoint(trunk, center)
        radius:radius startAngle:90 endAngle:270 clockwise:NO];
    [cap lineToPoint:NSMakePoint(trunk + 1, center - radius)];
    [cap closePath];
    if (merge) {
        NSAffineTransform *mirror = [NSAffineTransform transform];
        [mirror translateXBy:x0 + x1 yBy:0];
        [mirror scaleXBy:-1 yBy:1];
        for (NSBezierPath *path in @[upper, lower, cap]) [path transformUsingAffineTransform:mirror];
    }
    for (NSBezierPath *path in @[cap, lower, upper]) FillFlow(path);
    NSBezierPath *all = [NSBezierPath bezierPath];
    [all appendBezierPath:upper]; [all appendBezierPath:lower]; [all appendBezierPath:cap];
    return all;
}

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

static CGFloat FlowWidth(double watts) {
    return MIN(12, MAX(3, 2 + sqrt(MAX(0, watts)) * 1.4));
}

static NSString *Watts(double watts) {
    return [NSString stringWithFormat:@"%.1f W", MAX(0, watts)];
}

// One caption style for every node: muted name, emphasized watts.
static void FlowLabel(NSString *name, double watts, NSRect rect, NSTextAlignment alignment, NSColor *muted) {
    NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] init] autorelease];
    if (name.length) [text appendAttributedString:[[[NSAttributedString alloc] initWithString:[name stringByAppendingString:@"  "]
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                     NSForegroundColorAttributeName:muted}] autorelease]];
    [text appendAttributedString:[[[NSAttributedString alloc] initWithString:Watts(watts)
        attributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold],
                     NSForegroundColorAttributeName:NSColor.labelColor}] autorelease]];
    NSSize measured = text.size;
    CGFloat x = NSMinX(rect);
    if (alignment == NSTextAlignmentCenter) x = NSMidX(rect) - measured.width / 2;
    if (alignment == NSTextAlignmentRight) x = NSMaxX(rect) - measured.width;
    [text drawAtPoint:NSMakePoint(x, NSMidY(rect) - measured.height / 2)];
}

@implementation BattPowerFlowView {
    NSInteger _previewLimitPercent;
    BOOL _limitDragging;
    // The focus ring is for keyboard users; a click or the popover opening
    // makes the rail first responder without asking for a ring.
    BOOL _keyboardFocus;
    NSRect _healthTipRect;
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
    return NSMakeRect(20, 131, NSWidth(self.bounds) - 40, 6);
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

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)view; (void)tag; (void)point; (void)data;
    NSString *cycles = self.cycleCount >= 0 ?
        [NSString stringWithFormat:@" · %ld charge cycles", (long)self.cycleCount] : @"";
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
    CGFloat right = width - 20;
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
         (self.heatPaused && self.pluggedIn ? @"Charging paused · heat" :
         (self.topUpActive && self.pluggedIn ? @"Top Up · charging to 100%" :
         (self.dischargingToLimit && self.pluggedIn && limit > 0 ?
            [NSString stringWithFormat:@"Discharging to %ld%% · adapter on", (long)limit] :
         (self.sailing && self.pluggedIn && limit > 0 ?
            [NSString stringWithFormat:@"Sailing · charges again at %ld%%", (long)MAX(0, limit - self.sailingLevel)] :
          (statusCharging ? @"Charging" :
           (atLimit ? @"Charge limit reached" : (adapter ? @"Plugged in" : @"On battery"))))))));
    NSString *chargeText = self.chargePercent < 0 ? @"—%" :
        [NSString stringWithFormat:@"%ld%%", (long)charge];

    Text(chargeText, NSMakeRect(24, 158, 145, 60), 48, NSFontWeightSemibold,
         NSColor.labelColor, NSTextAlignmentLeft);
    // Orange marks the heat pause on the state line only; temperatures stay
    // neutral unless the CPU itself runs hot.
    Text(state, NSMakeRect(24, 142, 250, 18), 13, NSFontWeightRegular,
         self.heatPaused && self.pluggedIn ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor,
         NSTextAlignmentLeft);
    // Battery and processor temperatures side by side: Heat Protection acts
    // on the battery, while a hot fanless Mac is usually the processor.
    // Battery health joins them, as CleanMyMac's battery card does: the
    // capacity left against the design capacity, with the cycle count.
    NSColor *headerMuted = NSColor.secondaryLabelColor;
    BOOL showCPU = self.processorTemperatureCelsius > 0;
    BOOL showHealth = self.healthPercent > 0;
    NSInteger lines = (self.temperatureCelsius > 0) + showCPU + showHealth;
    CGFloat lineY = lines >= 3 ? 196 : (lines == 2 ? 186 : 174);
    if (self.temperatureCelsius > 0) {
        TemperatureLine(@"Battery", self.temperatureCelsius, NSColor.labelColor,
            NSMakeRect(right - 150, lineY, 146, 20), headerMuted);
        lineY -= lines >= 3 ? 20 : 22;
    }
    if (showCPU) {
        NSColor *color = self.processorTemperatureCelsius >= 85 ? NSColor.systemOrangeColor : NSColor.labelColor;
        TemperatureLine(@"CPU", self.processorTemperatureCelsius, color,
            NSMakeRect(right - 150, lineY, 146, 20), headerMuted);
        lineY -= lines >= 3 ? 20 : 22;
    }
    if (showHealth) {
        // Apple calls under 80% "Service Recommended"; only then is it a warning.
        NSColor *color = self.healthPercent < 80 ? NSColor.systemOrangeColor : NSColor.labelColor;
        NSRect healthRect = NSMakeRect(right - 150, lineY, 146, 20);
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
            (charge <= 20 ? NSColor.systemOrangeColor : WattAccentColor());
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
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(markerX - 1.5, 126, 3, 16) xRadius:2 yRadius:2] fill];
    }
    // The controller's non-interactive label never intercepts marker dragging.

    if (!self.hasTelemetry) {
        [self updateAnimationMask:[NSBezierPath bezierPath]];
        Text(@"Power flow unavailable", NSMakeRect(20, 23, width - 40, 40),
             12, NSFontWeightMedium, NSColor.secondaryLabelColor, NSTextAlignmentCenter);
        return;
    }

    // IOKit can briefly report battery charging power above adapter input.
    // Its derived system power is then clamped to zero; don't draw that as fact.
    if (charging && (!self.pluggedIn || self.adapterWatts < self.batteryWatts + 0.5 ||
                     self.systemWatts < 0.5)) {
        [self updateAnimationMask:[NSBezierPath bezierPath]];
        Text(@"Power readings updating", NSMakeRect(20, 52, width - 40, 20),
             12, NSFontWeightMedium, NSColor.labelColor, NSTextAlignmentCenter);
        Text(@"Adapter and battery data disagree", NSMakeRect(20, 30, width - 40, 18),
             10, NSFontWeightRegular, NSColor.secondaryLabelColor, NSTextAlignmentCenter);
        return;
    }

    NSColor *muted = [NSColor colorWithCalibratedWhite:dark ? 0.75 : 0.36 alpha:1];
    NSBezierPath *mask = [NSBezierPath bezierPath];
    CGFloat x0 = 54, x1 = width - 54;
    if (adapter && charging) {
        CGFloat toBattery = FlowWidth(self.batteryWatts);
        CGFloat toMac = FlowWidth(self.systemWatts);
        [mask appendBezierPath:Fork(x0, x1, toBattery, toMac, NO)];
        FlowNode(@"powerplug.fill", NSMakeRect(20, 32, 34, 34), muted, dark);
        FlowNode(@"battery.100percent", NSMakeRect(width - 54, 53, 34, 34), muted, dark);
        FlowNode(@"laptopcomputer", NSMakeRect(width - 54, 11, 34, 34), muted, dark);
        // Captions sit beside their own node: source under the plug,
        // destinations right-aligned against their nodes, outside the strokes.
        FlowLabel(@"Battery", self.batteryWatts, NSMakeRect(x0, 86, x1 - x0 - 8, 14), NSTextAlignmentRight, muted);
        FlowLabel(@"Mac", self.systemWatts, NSMakeRect(x0, 0, x1 - x0 - 8, 14), NSTextAlignmentRight, muted);
        FlowLabel(@"", self.adapterWatts, NSMakeRect(4, 12, 66, 16), NSTextAlignmentCenter, muted);
    } else if (hybrid) {
        CGFloat fromAdapter = FlowWidth(self.adapterWatts);
        CGFloat fromBattery = FlowWidth(-self.batteryWatts);
        [mask appendBezierPath:Fork(x0, x1, fromAdapter, fromBattery, YES)];
        FlowNode(@"powerplug.fill", NSMakeRect(20, 53, 34, 34), muted, dark);
        FlowNode(@"battery.100percent", NSMakeRect(20, 11, 34, 34), muted, dark);
        FlowNode(@"laptopcomputer", NSMakeRect(width - 54, 32, 34, 34), muted, dark);
        FlowLabel(@"Adapter", self.adapterWatts, NSMakeRect(x0 + 8, 86, 180, 14), NSTextAlignmentLeft, muted);
        FlowLabel(@"Battery", -self.batteryWatts, NSMakeRect(x0 + 8, 0, 180, 14), NSTextAlignmentLeft, muted);
        FlowLabel(@"", self.systemWatts, NSMakeRect(width - 70, 12, 66, 16), NSTextAlignmentCenter, muted);
    } else {
        BOOL fromBattery = !adapter;
        double watts = fromBattery ? -self.batteryWatts : self.adapterWatts;
        if (watts > 0.25) [mask appendBezierPath:
            Flow(x0, 50, x1, 50, FlowWidth(watts), FlowWidth(watts))];
        else {
            // No measurable power yet: a faint track, not a full-strength stream.
            [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
            [Band(x0 + FlowNodeGap, 51.5, 48.5, x1 - FlowNodeGap, 51.5, 48.5, YES, YES) fill];
        }
        FlowNode(fromBattery ? @"battery.100percent" : @"powerplug.fill",
                 NSMakeRect(20, 33, 34, 34), muted, dark);
        FlowNode(@"laptopcomputer", NSMakeRect(width - 54, 33, 34, 34), muted, dark);
        Text(watts > 0.25 ? Watts(watts) : @"Power readings updating…",
             NSMakeRect(75, 78, width - 150, 19), 14, NSFontWeightSemibold,
             NSColor.labelColor, NSTextAlignmentCenter);
        Text(fromBattery ? @"Battery" : @"Adapter", NSMakeRect(12, 9, 50, 16),
             10, NSFontWeightMedium, muted, NSTextAlignmentCenter);
        Text(@"Mac", NSMakeRect(width - 61, 9, 45, 16),
             10, NSFontWeightMedium, muted, NSTextAlignmentCenter);
        if (adapter && !charging) {
            Text(@"Battery held · 0 W", NSMakeRect(84, 9, width - 168, 17),
                 10, NSFontWeightMedium, muted, NSTextAlignmentCenter);
        }
    }
    [self updateAnimationMask:mask];
}

@end
