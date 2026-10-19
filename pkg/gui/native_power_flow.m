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

static NSBezierPath *Flow(CGFloat x0, CGFloat y0, CGFloat x1, CGFloat y1,
                 CGFloat startWidth, CGFloat endWidth) {
    CGFloat thickness = MAX(22, (startWidth + endWidth) / 2);
    CGFloat span = x1 - x0;
    NSBezierPath *path = [NSBezierPath bezierPath];
    CGFloat middle = (x0+x1)/2, center = (y0+y1)/2;
    CGFloat port = MIN(18,thickness);
    CGFloat entry = span * 0.18;
    [path moveToPoint:NSMakePoint(x0, y0 + port/2)];
    [path curveToPoint:NSMakePoint(x0+entry,y0+thickness/2)
        controlPoint1:NSMakePoint(x0+entry*0.4,y0+port/2)
        controlPoint2:NSMakePoint(x0+entry*0.6,y0+thickness/2)];
    [path curveToPoint:NSMakePoint(middle, center + 10)
         controlPoint1:NSMakePoint(x0 + entry*1.4, y0 + thickness/2)
         controlPoint2:NSMakePoint(middle - span * 0.18, center + 10)];
    [path curveToPoint:NSMakePoint(x1-entry, y1 + thickness/2)
         controlPoint1:NSMakePoint(middle + span * 0.18, center + 10)
         controlPoint2:NSMakePoint(x1 - entry*1.4, y1 + thickness/2)];
    [path curveToPoint:NSMakePoint(x1,y1+port/2)
        controlPoint1:NSMakePoint(x1-entry*0.6,y1+thickness/2)
        controlPoint2:NSMakePoint(x1-entry*0.4,y1+port/2)];
    [path lineToPoint:NSMakePoint(x1, y1 - port/2)];
    [path curveToPoint:NSMakePoint(x1-entry,y1-thickness/2)
        controlPoint1:NSMakePoint(x1-entry*0.4,y1-port/2)
        controlPoint2:NSMakePoint(x1-entry*0.6,y1-thickness/2)];
    [path curveToPoint:NSMakePoint(middle, center - 10)
         controlPoint1:NSMakePoint(x1 - entry*1.4, y1 - thickness/2)
         controlPoint2:NSMakePoint(middle + span * 0.18, center - 10)];
    [path curveToPoint:NSMakePoint(x0+entry, y0 - thickness/2)
         controlPoint1:NSMakePoint(middle - span * 0.18, center - 10)
         controlPoint2:NSMakePoint(x0 + entry*1.4, y0 - thickness/2)];
    [path curveToPoint:NSMakePoint(x0,y0-port/2)
        controlPoint1:NSMakePoint(x0+entry*0.6,y0-thickness/2)
        controlPoint2:NSMakePoint(x0+entry*0.4,y0-port/2)];
    [path closePath];
    NSColor *accent = FlowColor();
    NSGradient *gradient = [[[NSGradient alloc] initWithColors:@[
        [accent blendedColorWithFraction:0.25 ofColor:NSColor.whiteColor],
        [accent blendedColorWithFraction:0.40 ofColor:WattSurfaceColor(NO)],
        [accent blendedColorWithFraction:0.25 ofColor:NSColor.whiteColor]]]
        autorelease];
    [gradient drawInBezierPath:path angle:0];
    return path;
}

// One continuous outline, with a rounded inner junction instead of a sharp seam.
static NSBezierPath *Fork(CGFloat x0, CGFloat x1, CGFloat upperWidth,
                          CGFloat lowerWidth, BOOL merge) {
    CGFloat span = x1 - x0, junction = x0 + span * 0.48;
    CGFloat upper = MIN(9, upperWidth / 2), lower = MIN(9, lowerWidth / 2);
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(x0, 58)];
    [path curveToPoint:NSMakePoint(x1, 70 + upper)
        controlPoint1:NSMakePoint(x0 + span * 0.38, 58)
        controlPoint2:NSMakePoint(x1 - span * 0.38, 70 + upper)];
    [path lineToPoint:NSMakePoint(x1, 70 - upper)];
    [path curveToPoint:NSMakePoint(junction, 52)
        controlPoint1:NSMakePoint(x1 - span * 0.30, 70 - upper)
        controlPoint2:NSMakePoint(junction + 24, 52)];
    [path curveToPoint:NSMakePoint(junction - 3, 49)
        controlPoint1:NSMakePoint(junction - 1.66, 52)
        controlPoint2:NSMakePoint(junction - 3, 50.66)];
    [path curveToPoint:NSMakePoint(junction, 46)
        controlPoint1:NSMakePoint(junction - 3, 47.34)
        controlPoint2:NSMakePoint(junction - 1.66, 46)];
    [path curveToPoint:NSMakePoint(x1, 28 + lower)
        controlPoint1:NSMakePoint(junction + 24, 46)
        controlPoint2:NSMakePoint(x1 - span * 0.30, 28 + lower)];
    [path lineToPoint:NSMakePoint(x1, 28 - lower)];
    [path curveToPoint:NSMakePoint(x0, 40)
        controlPoint1:NSMakePoint(x1 - span * 0.38, 28 - lower)
        controlPoint2:NSMakePoint(x0 + span * 0.38, 40)];
    [path closePath];
    if (merge) {
        NSAffineTransform *mirror = [NSAffineTransform transform];
        [mirror translateXBy:x0 + x1 yBy:0];
        [mirror scaleXBy:-1 yBy:1];
        [path transformUsingAffineTransform:mirror];
    }
    NSGradient *gradient = [[[NSGradient alloc] initWithStartingColor:FlowColor()
        endingColor:[FlowColor() blendedColorWithFraction:0.18 ofColor:NSColor.whiteColor]] autorelease];
    [gradient drawInBezierPath:path angle:0];
    return path;
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
    return MIN(21, MAX(7, 4 + sqrt(MAX(0, watts)) * 2.2));
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
            (id)[NSColor.whiteColor colorWithAlphaComponent:0.38].CGColor,
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
        animation.duration = 2.2; animation.repeatCount = HUGE_VALF;
        [_flowHighlight addAnimation:animation forKey:@"flow"];
    }
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _chargePercent = -1;
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

- (BOOL)acceptsFirstResponder {
    return self.limitEditable;
}

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
    BOOL adapter = self.hasTelemetry && self.pluggedIn && self.adapterWatts > 0.25;
    BOOL charging = self.hasTelemetry && self.batteryWatts > 0.25;
    BOOL statusCharging = self.chargingStateKnown ? self.batteryCharging : charging;
    // On adapter power a held battery reads a few hundred mW either way;
    // don't present that noise as the battery helping power the Mac.
    BOOL discharging = self.hasTelemetry && self.batteryWatts < (self.pluggedIn ? -0.75 : -0.25);
    BOOL hybrid = adapter && discharging;
    BOOL atLimit = adapter && !charging && !discharging &&
        limit >= 0 && limit < 100 && self.chargePercent >= limit - 1;
    NSString *state = !self.hasTelemetry ? @"Power data unavailable" :
        (hybrid ? @"AC + battery" :
         (self.heatPaused && self.pluggedIn ? @"Charging paused · heat" :
          (statusCharging ? @"Charging" :
           (atLimit ? @"Charge limit reached" : (adapter ? @"Plugged in" : @"On battery")))));
    NSString *chargeText = self.chargePercent < 0 ? @"—%" :
        [NSString stringWithFormat:@"%ld%%", (long)charge];

    Text(chargeText, NSMakeRect(24, 158, 145, 60), 48, NSFontWeightSemibold,
         NSColor.labelColor, NSTextAlignmentLeft);
    Text(state, NSMakeRect(24, 140, 250, 18), 13, NSFontWeightRegular,
         NSColor.secondaryLabelColor, NSTextAlignmentLeft);
    // Battery and processor temperatures side by side: Heat Protection acts
    // on the battery, while a hot fanless Mac is usually the processor.
    NSColor *headerMuted = NSColor.secondaryLabelColor;
    BOOL showCPU = self.processorTemperatureCelsius > 0;
    if (self.temperatureCelsius > 0) {
        NSColor *color = self.heatPaused && self.pluggedIn ? NSColor.systemOrangeColor : NSColor.labelColor;
        TemperatureLine(@"Battery", self.temperatureCelsius, color,
            NSMakeRect(right - 150, showCPU ? 186 : 174, 146, 20), headerMuted);
    }
    if (showCPU) {
        NSColor *color = self.processorTemperatureCelsius >= 85 ? NSColor.systemOrangeColor : NSColor.labelColor;
        TemperatureLine(@"CPU", self.processorTemperatureCelsius, color,
            NSMakeRect(right - 150, 164, 146, 20), headerMuted);
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
    [NSColor.labelColor setFill];
    if (limit >= 0) [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(markerX - 1.5, 126, 3, 16)
                                     xRadius:2 yRadius:2] fill];
    // The controller's non-interactive label never intercepts marker dragging.
    [[NSColor colorWithCalibratedWhite:dark ? 0.28 : 0.80 alpha:1] setFill];
    NSRectFill(NSMakeRect(14, 104, width - 28, 0.7));

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
            Flow(x0, 50, x1, 50, 28, 28)];
        else {
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationSourceOver;
            NSBezierPath *waiting = Flow(x0,50,x1,50,28,28);
            [WattSurfaceColor(YES) setFill]; [waiting fill];
            [NSGraphicsContext restoreGraphicsState];
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
