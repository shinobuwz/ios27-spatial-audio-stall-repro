//
//  StallReproViewController.m
//  SpatialAudioStallRepro
//

#import "StallReproViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#import <os/signpost.h>

static os_log_t gSignpostLog;

static double NowMS(void) {
    return CACurrentMediaTime() * 1000.0;
}

/// Decode AVAudioSessionCategoryOptions into readable names.
static NSString *OptionsString(AVAudioSessionCategoryOptions options) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (options & AVAudioSessionCategoryOptionMixWithOthers) [parts addObject:@"MixWithOthers"];
    if (options & AVAudioSessionCategoryOptionDuckOthers) [parts addObject:@"DuckOthers"];
    if (options & AVAudioSessionCategoryOptionAllowBluetoothHFP) [parts addObject:@"AllowBluetoothHFP"];
    if (options & AVAudioSessionCategoryOptionDefaultToSpeaker) [parts addObject:@"DefaultToSpeaker"];
    if ((options & AVAudioSessionCategoryOptionInterruptSpokenAudioAndMixWithOthers) ==
        AVAudioSessionCategoryOptionInterruptSpokenAudioAndMixWithOthers) {
        [parts addObject:@"InterruptSpokenAudioAndMixWithOthers"];
    }
    if (options & AVAudioSessionCategoryOptionAllowBluetoothA2DP) [parts addObject:@"AllowBluetoothA2DP"];
    if (options & AVAudioSessionCategoryOptionAllowAirPlay) [parts addObject:@"AllowAirPlay"];
    if (options & AVAudioSessionCategoryOptionOverrideMutedMicrophoneInterruption) {
        [parts addObject:@"OverrideMutedMicrophoneInterruption"];
    }
    NSString *names = parts.count ? [parts componentsJoinedByString:@"|"] : @"none";
    return [NSString stringWithFormat:@"%lu(%@)", (unsigned long)options, names];
}

@interface StallReproViewController ()

@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) AVAudioSession *session;

@property (nonatomic, strong) AVAudioPlayer *tonePlayer;
@property (nonatomic, strong) AVAudioEngine *toneEngine;
@property (nonatomic, strong) AVAudioPlayerNode *toneNode;
@property (nonatomic, assign) BOOL useEngineTone;
@property (nonatomic, assign) BOOL dualTone;
@property (nonatomic, strong) AVAudioEngine *inputEngine;
@property (nonatomic, assign) NSInteger inputBufferCount;
@property (nonatomic, assign) BOOL firstInputBufferLogged;

@property (nonatomic, strong) NSFileHandle *logFile;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *stepMs;

@property (nonatomic, copy) NSString *runMode;
@property (nonatomic, assign) CFTimeInterval runStart;
@property (nonatomic, assign) double configStart;
@property (nonatomic, assign) BOOL running;

/// Default: AllowBluetooth | DefaultToSpeaker | MixWithOthers (13).
/// Override with launch arguments -opts12 / -opts13 / -opts237.
@property (nonatomic, assign) AVAudioSessionCategoryOptions reproOptions;

@end

@implementation StallReproViewController

- (instancetype)init {
    if ((self = [super init])) {
        gSignpostLog = os_log_create("com.example.stallrepro", "AVAudioSessionStall");
        _session = [AVAudioSession sharedInstance];
        _reproOptions = AVAudioSessionCategoryOptionAllowBluetoothHFP |
                        AVAudioSessionCategoryOptionDefaultToSpeaker |
                        AVAudioSessionCategoryOptionMixWithOthers;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Accept both "-auto-repro" (Xcode / simctl) and "auto-repro" (devicectl).
    NSArray<NSString *> *arguments = [NSProcessInfo processInfo].arguments;
    for (NSString *key in arguments) {
        if ([key isEqualToString:@"-opts12"] || [key isEqualToString:@"opts12"]) {
            self.reproOptions = AVAudioSessionCategoryOptionAllowBluetoothHFP |
                                AVAudioSessionCategoryOptionDefaultToSpeaker;
        } else if ([key isEqualToString:@"-opts13"] || [key isEqualToString:@"opts13"]) {
            self.reproOptions = AVAudioSessionCategoryOptionAllowBluetoothHFP |
                                AVAudioSessionCategoryOptionDefaultToSpeaker |
                                AVAudioSessionCategoryOptionMixWithOthers;
        } else if ([key isEqualToString:@"-opts237"] || [key isEqualToString:@"opts237"]) {
            // Exactly what the shipping game SDK uses.
            self.reproOptions = (AVAudioSessionCategoryOptions)237;
        } else if ([key isEqualToString:@"-engine-tone"] || [key isEqualToString:@"engine-tone"]) {
            // Render the tone from an app-owned AudioUnit instead of AVAudioPlayer.
            self.useEngineTone = YES;
        } else if ([key isEqualToString:@"-dual-tone"] || [key isEqualToString:@"dual-tone"]) {
            // Two rendering units at the same time.
            self.dualTone = YES;
        }
    }

    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *hint = [[UILabel alloc] init];
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.text = @"Precondition: AirPods connected, Spatial Audio + Head Tracking enabled.\n"
                 @"Repro: tap 1 (play 440 Hz), then tap 3 (switch while playing).\n"
                 @"Control: tap 4 (stop playback first) - should finish in milliseconds.";

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [stack addArrangedSubview:hint];
    [stack addArrangedSubview:[self button:@"1) Play 440 Hz (AVAudioPlayer)" action:@selector(toggleTone)]];
    [stack addArrangedSubview:[self button:@"2) Stop playback" action:@selector(stopToneAndLog)]];
    [stack addArrangedSubview:[self button:@"3) Repro: switch to PlayAndRecord + VoiceChat while playing" action:@selector(runReproByHand)]];
    [stack addArrangedSubview:[self button:@"4) Control: stop playback first, then switch" action:@selector(runControlByHand)]];
    [stack addArrangedSubview:[self button:@"5) Dump audio session" action:@selector(dumpSession)]];
    [stack addArrangedSubview:[self button:@"6) Share log" action:@selector(shareLog)]];

    self.logView = [[UITextView alloc] init];
    self.logView.editable = NO;
    self.logView.alwaysBounceVertical = YES;
    self.logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:stack];
    [self.view addSubview:self.logView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [self.logView.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:8],
        [self.logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
    ]];

    [self observeSession];
    [self log:@"ready app=%@ options=%@", [[NSBundle mainBundle] bundleIdentifier],
               OptionsString(self.reproOptions)];
    [self logEnvironment];
    [self requestMicrophonePermissionAndMaybeAutoRun];
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.titleLabel.numberOfLines = 2;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:40].active = YES;
    return button;
}

#pragma mark - Logging

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    double relative = self.runStart > 0 ? (CACurrentMediaTime() - self.runStart) * 1000.0 : 0;
    NSString *stamped = [NSString stringWithFormat:@"[+%9.1fms] %@", relative, line];

    NSLog(@"[stallrepro] %@", stamped);
    [self appendToLogFile:stamped];

    if ([NSThread isMainThread]) {
        self.logView.text = [self.logView.text stringByAppendingFormat:@"%@\n", stamped];
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.logView.text = [self.logView.text stringByAppendingFormat:@"%@\n", stamped];
            [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
        });
    }
}

- (void)appendToLogFile:(NSString *)line {
    if (!self.logFile) {
        NSString *documents =
            [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *path = [documents stringByAppendingPathComponent:@"stall_repro.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:nil attributes:nil];
        }
        self.logFile = [NSFileHandle fileHandleForWritingAtPath:path];
        [self.logFile seekToEndOfFile];
    }
    [self.logFile writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [self.logFile synchronizeFile];
}

- (void)shareLog {
    NSString *documents =
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [documents stringByAppendingPathComponent:@"stall_repro.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self log:@"shareLog: missing %@", path];
        return;
    }
    UIActivityViewController *controller =
        [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                           applicationActivities:nil];
    controller.popoverPresentationController.sourceView = self.view;
    controller.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:controller animated:YES completion:nil];
}

#pragma mark - Measurement helpers

- (os_signpost_id_t)beginStep:(NSString *)name {
    os_signpost_id_t sid = os_signpost_id_generate(gSignpostLog);
    os_signpost_interval_begin(gSignpostLog, sid, "avsession-call", "%{public}s", name.UTF8String);
    return sid;
}

- (void)endStep:(NSString *)name
       signpost:(os_signpost_id_t)sid
          start:(double)start
          error:(NSError *)error
         detail:(NSString *)detail {
    double ms = NowMS() - start;
    os_signpost_interval_end(gSignpostLog, sid, "avsession-call", "%{public}s", name.UTF8String);
    self.stepMs[name] = @(ms);

    NSMutableString *line = [NSMutableString stringWithFormat:@"STEP %@ %.1fms", name, ms];
    if (detail.length) [line appendFormat:@" %@", detail];
    if (error) [line appendFormat:@" error=%@(%ld)", error.localizedDescription, (long)error.code];
    [self log:@"%@", line];
}

- (NSString *)routeString {
    AVAudioSessionRouteDescription *route = self.session.currentRoute;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (AVAudioSessionPortDescription *port in route.inputs) {
        [parts addObject:[NSString stringWithFormat:@"in:%@(ch=%lu)",
                                                    port.portType, (unsigned long)port.channels.count]];
    }
    for (AVAudioSessionPortDescription *port in route.outputs) {
        [parts addObject:[NSString stringWithFormat:@"out:%@(spatial=%d,ch=%lu)",
                                                    port.portType,
                                                    port.isSpatialAudioEnabled,
                                                    (unsigned long)port.channels.count]];
    }
    return parts.count ? [parts componentsJoinedByString:@","] : @"none";
}

- (void)logEnvironment {
    UIDevice *device = [UIDevice currentDevice];
    NSProcessInfo *process = [NSProcessInfo processInfo];
    [self log:@"ENV device=%@ model=%@ system=%@ %@ lowPower=%d thermal=%ld",
               device.name, device.model, device.systemName, device.systemVersion,
               process.isLowPowerModeEnabled, (long)process.thermalState];
}

- (void)dumpSession {
    [self log:@"SESSION category=%@ mode=%@ options=%@ sampleRate=%.0f ioBuffer=%.4f "
               @"inCh=%ld outCh=%ld inAvailable=%d route=%@",
               self.session.category, self.session.mode,
               OptionsString(self.session.categoryOptions), self.session.sampleRate,
               self.session.IOBufferDuration, (long)self.session.inputNumberOfChannels,
               (long)self.session.outputNumberOfChannels, self.session.isInputAvailable,
               [self routeString]];
    [self log:@"SESSION otherAudioPlaying=%d shouldSilenceSecondary=%d volume=%.2f",
               self.session.isOtherAudioPlaying,
               self.session.secondaryAudioShouldBeSilencedHint, self.session.outputVolume];
}

#pragma mark - Session notifications

- (void)observeSession {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:nil];
    [center addObserver:self selector:@selector(mediaServicesReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [center addObserver:self selector:@selector(mediaServicesLost:) name:AVAudioSessionMediaServicesWereLostNotification object:nil];
}

- (void)routeChanged:(NSNotification *)note {
    NSNumber *reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
    NSNumber *spatial = note.userInfo[AVAudioSessionSpatialAudioEnabledKey];
    NSString *route = [self routeString];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self log:@"NOTIFY route-change reason=%d spatial=%@ route=%@",
                   reason.intValue, spatial ? spatial.stringValue : @"nil", route];
    });
}

- (void)interruption:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self log:@"NOTIFY interruption type=%lu", (unsigned long)type];
    });
}

- (void)mediaServicesReset:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{ [self log:@"NOTIFY media-services-reset"]; });
}

- (void)mediaServicesLost:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{ [self log:@"NOTIFY media-services-lost"]; });
}

#pragma mark - Microphone permission / auto run

- (void)requestMicrophonePermissionAndMaybeAutoRun {
    NSArray<NSString *> *arguments = [NSProcessInfo processInfo].arguments;
    NSString *mode = nil;
    if ([arguments containsObject:@"-auto-repro"] || [arguments containsObject:@"auto-repro"]) {
        mode = @"repro";
    } else if ([arguments containsObject:@"-auto-control"] || [arguments containsObject:@"auto-control"]) {
        mode = @"control";
    }

    __weak typeof(self) weakSelf = self;
    void (^afterPermission)(BOOL) = ^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf log:@"PERMISSION microphone granted=%d", granted];
            if (!mode) return;
            [weakSelf log:@"AUTO scheduled mode=%@", mode];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf runMode:mode];
            });
        });
    };

    [AVAudioApplication requestRecordPermissionWithCompletionHandler:afterPermission];
}

#pragma mark - Test tone

- (void)toggleTone {
    if (self.tonePlayer || self.toneEngine) {
        [self stopToneAndLog];
    } else {
        [self startTone];
    }
}

- (void)startTone {
    if (!self.useEngineTone) {
        [self startPlayerTone];
    }
    if (self.useEngineTone || self.dualTone) {
        [self startEngineTone];
    }
    [self log:@"PHASE tone playing=%@ route=%@", [self toneStateString], [self routeString]];
}

- (void)startPlayerTone {
    NSError *error = nil;
    self.tonePlayer = [[AVAudioPlayer alloc] initWithData:[self toneWAVData] error:&error];
    if (!self.tonePlayer) {
        [self log:@"tone init failed: %@", error.localizedDescription];
        return;
    }
    self.tonePlayer.numberOfLoops = -1;
    [self.tonePlayer prepareToPlay];
    [self.tonePlayer play];
}

/// Continuous 440 Hz rendered by an AVAudioEngine + AVAudioPlayerNode
/// (an AudioUnit owned by this process, not the shared media player).
- (void)startEngineTone {
    self.toneEngine = [[AVAudioEngine alloc] init];
    self.toneNode = [[AVAudioPlayerNode alloc] init];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                            sampleRate:48000
                                                              channels:1
                                                           interleaved:NO];
    [self.toneEngine attachNode:self.toneNode];
    [self.toneEngine connect:self.toneNode to:self.toneEngine.mainMixerNode format:format];

    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:48000];
    buffer.frameLength = 48000;
    float *samples = buffer.floatChannelData[0];
    for (int i = 0; i < 48000; i++) {
        samples[i] = 0.15f * sinf(2.0f * (float)M_PI * 440.0f * i / 48000.0f);
    }
    [self.toneNode scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];

    NSError *error = nil;
    BOOL started = [self.toneEngine startAndReturnError:&error];
    [self.toneNode play];
    [self log:@"PHASE engine-tone started=%d running=%d error=%@",
               started, self.toneEngine.isRunning, error.localizedDescription];
}

- (NSString *)toneStateString {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (self.tonePlayer) [parts addObject:[NSString stringWithFormat:@"player=%d", self.tonePlayer.isPlaying]];
    if (self.toneEngine) [parts addObject:[NSString stringWithFormat:@"engine=%d", self.toneEngine.isRunning]];
    return parts.count ? [parts componentsJoinedByString:@","] : @"none";
}

- (void)stopToneAndLog {
    NSString *state = [self toneStateString];
    [self.tonePlayer stop];
    self.tonePlayer = nil;
    if (self.toneNode) [self.toneNode stop];
    if (self.toneEngine) [self.toneEngine stop];
    self.toneNode = nil;
    self.toneEngine = nil;
    [self log:@"PHASE tone stopped was=%@ route=%@", state, [self routeString]];
}

/// 1 s of 440 Hz, 44.1 kHz, mono, 16-bit PCM in a RIFF/WAVE container.
- (NSData *)toneWAVData {
    const int sampleRate = 44100;
    const int frames = sampleRate;
    NSMutableData *data = [NSMutableData data];

    uint32_t chunkSize = 36 + frames * 2;
    uint32_t subchunk1Size = 16;
    uint16_t audioFormat = 1;
    uint16_t channels = 1;
    uint32_t rate = sampleRate;
    uint32_t byteRate = sampleRate * 2;
    uint16_t blockAlign = 2;
    uint16_t bitsPerSample = 16;
    uint32_t subchunk2Size = frames * 2;

    [data appendBytes:"RIFF" length:4];
    [data appendBytes:&chunkSize length:4];
    [data appendBytes:"WAVEfmt " length:8];
    [data appendBytes:&subchunk1Size length:4];
    [data appendBytes:&audioFormat length:2];
    [data appendBytes:&channels length:2];
    [data appendBytes:&rate length:4];
    [data appendBytes:&byteRate length:4];
    [data appendBytes:&blockAlign length:2];
    [data appendBytes:&bitsPerSample length:2];
    [data appendBytes:"data" length:4];
    [data appendBytes:&subchunk2Size length:4];

    for (int i = 0; i < frames; i++) {
        double phase = 2.0 * M_PI * 440.0 * i / sampleRate;
        int16_t sample = (int16_t)(sin(phase) * 12000);
        [data appendBytes:&sample length:2];
    }
    return data;
}

#pragma mark - Runs

- (void)runReproByHand {
    [self runMode:@"repro"];
}

- (void)runControlByHand {
    [self runMode:@"control"];
}

- (void)runMode:(NSString *)mode {
    if (self.running) {
        [self log:@"SKIP run already in progress (%@)", self.runMode];
        return;
    }
    self.running = YES;
    self.runMode = mode;
    self.runStart = CACurrentMediaTime();
    self.stepMs = [NSMutableDictionary dictionary];
    self.firstInputBufferLogged = NO;
    self.inputBufferCount = 0;

    [self log:@"===== RUN mode=%@ options=%@ tone=%@ =====",
               mode, OptionsString(self.reproOptions),
               self.useEngineTone ? @"engine" : (self.dualTone ? @"dual" : @"player")];
    [self logEnvironment];

    // Step 1: an actively playing audio unit (AVAudioPlayer -> its own AudioUnit).
    NSError *error = nil;

    os_signpost_id_t signpost = [self beginStep:@"prepare.setCategory(Playback)"];
    double start = NowMS();
    [self.session setCategory:AVAudioSessionCategoryPlayback error:&error];
    [self endStep:@"prepare.setCategory(Playback)" signpost:signpost start:start error:error detail:@""];

    signpost = [self beginStep:@"prepare.setActive(YES)"];
    start = NowMS();
    BOOL ok = [self.session setActive:YES error:&error];
    [self endStep:@"prepare.setActive(YES)" signpost:signpost start:start error:error
           detail:[NSString stringWithFormat:@"ok=%d", ok]];

    [self startTone];
    [self log:@"PHASE pre-switch route=%@ category=%@ mode=%@ sampleRate=%.0f inCh=%ld outCh=%ld",
               [self routeString], self.session.category, self.session.mode, self.session.sampleRate,
               (long)self.session.inputNumberOfChannels, (long)self.session.outputNumberOfChannels];

    // Let the playback route settle before switching, as an app would.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([mode isEqualToString:@"control"]) {
            [weakSelf runControlSwitch];
        } else {
            [weakSelf switchToRecord];
        }
    });
}

/// Control: stop the playing audio unit first, then switch. Expect milliseconds.
- (void)runControlSwitch {
    [self log:@"PHASE control-stop-player"];
    [self stopToneAndLog];
    [NSThread sleepForTimeInterval:0.3];

    NSError *error = nil;
    os_signpost_id_t signpost = [self beginStep:@"control.setActive(NO)"];
    double start = NowMS();
    BOOL ok = [self.session setActive:NO error:&error];
    [self endStep:@"control.setActive(NO)" signpost:signpost start:start error:error
           detail:[NSString stringWithFormat:@"ok=%d", ok]];

    [self switchToRecord];
}

/// The measured sequence: Playback/A2DP -> PlayAndRecord + VoiceChat/HFP.
- (void)switchToRecord {
    self.configStart = NowMS();
    NSError *error = nil;

    [self log:@"PHASE switch-to-record options=%@ preRoute=%@",
               OptionsString(self.reproOptions), [self routeString]];

    os_signpost_id_t signpost = [self beginStep:@"setCategory(PlayAndRecord)"];
    double start = NowMS();
    [self.session setCategory:AVAudioSessionCategoryPlayAndRecord
                  withOptions:self.reproOptions
                        error:&error];
    [self endStep:@"setCategory(PlayAndRecord)" signpost:signpost start:start error:error
           detail:[NSString stringWithFormat:@"options=%lu", (unsigned long)self.reproOptions]];

    signpost = [self beginStep:@"setMode(VoiceChat)"];
    start = NowMS();
    [self.session setMode:AVAudioSessionModeVoiceChat error:&error];
    [self endStep:@"setMode(VoiceChat)" signpost:signpost start:start error:error detail:@""];

    signpost = [self beginStep:@"inputNumberOfChannels"];
    start = NowMS();
    NSInteger inputChannels = [self.session inputNumberOfChannels];
    [self endStep:@"inputNumberOfChannels" signpost:signpost start:start error:nil
           detail:[NSString stringWithFormat:@"value=%ld", (long)inputChannels]];

    signpost = [self beginStep:@"outputNumberOfChannels"];
    start = NowMS();
    NSInteger outputChannels = [self.session outputNumberOfChannels];
    [self endStep:@"outputNumberOfChannels" signpost:signpost start:start error:nil
           detail:[NSString stringWithFormat:@"value=%ld", (long)outputChannels]];

    // Reading the spatial-audio flag of the output port is reported to be slow
    // during the transition; measure it explicitly.
    signpost = [self beginStep:@"outputPort.isSpatialAudioEnabled"];
    start = NowMS();
    AVAudioSessionPortDescription *outputPort = self.session.currentRoute.outputs.firstObject;
    BOOL spatial = outputPort.isSpatialAudioEnabled;
    [self endStep:@"outputPort.isSpatialAudioEnabled" signpost:signpost start:start error:nil
           detail:[NSString stringWithFormat:@"port=%@ spatial=%d", outputPort.portType, spatial]];

    signpost = [self beginStep:@"setPreferredSampleRate(48000)"];
    start = NowMS();
    [self.session setPreferredSampleRate:48000 error:&error];
    [self endStep:@"setPreferredSampleRate(48000)" signpost:signpost start:start error:error detail:@""];

    signpost = [self beginStep:@"setPreferredIOBufferDuration(0.01)"];
    start = NowMS();
    [self.session setPreferredIOBufferDuration:0.01 error:&error];
    [self endStep:@"setPreferredIOBufferDuration(0.01)" signpost:signpost start:start error:error detail:@""];

    signpost = [self beginStep:@"setPreferredInputNumberOfChannels(1)"];
    start = NowMS();
    [self.session setPreferredInputNumberOfChannels:1 error:&error];
    [self endStep:@"setPreferredInputNumberOfChannels(1)" signpost:signpost start:start error:error detail:@""];

    signpost = [self beginStep:@"setPreferredOutputNumberOfChannels(2)"];
    start = NowMS();
    [self.session setPreferredOutputNumberOfChannels:2 error:&error];
    [self endStep:@"setPreferredOutputNumberOfChannels(2)" signpost:signpost start:start error:error detail:@""];

    signpost = [self beginStep:@"setActive(YES)"];
    start = NowMS();
    BOOL ok = [self.session setActive:YES error:&error];
    [self endStep:@"setActive(YES)" signpost:signpost start:start error:error
           detail:[NSString stringWithFormat:@"ok=%d", ok]];

    // Configuration cost only: the prepare/cleanup steps are not part of it.
    NSArray<NSString *> *configSteps = @[
        @"setCategory(PlayAndRecord)",
        @"setMode(VoiceChat)",
        @"inputNumberOfChannels",
        @"outputNumberOfChannels",
        @"outputPort.isSpatialAudioEnabled",
        @"setPreferredSampleRate(48000)",
        @"setPreferredIOBufferDuration(0.01)",
        @"setPreferredInputNumberOfChannels(1)",
        @"setPreferredOutputNumberOfChannels(2)",
        @"setActive(YES)",
    ];
    double total = 0;
    for (NSString *name in configSteps) total += self.stepMs[name].doubleValue;
    double sinceConfigStart = NowMS() - self.configStart;

    [self log:@"SUMMARY mode=%@ options=%lu total_ms=%.1f category_ms=%.1f mode_ms=%.1f "
               @"input_ch_ms=%.1f output_ch_ms=%.1f spatial_getter_ms=%.1f sample_rate_ms=%.1f "
               @"io_buffer_ms=%.1f pref_in_ms=%.1f pref_out_ms=%.1f active_ms=%.1f slow=%d route=%@",
               self.runMode, (unsigned long)self.reproOptions, total,
               self.stepMs[@"setCategory(PlayAndRecord)"].doubleValue,
               self.stepMs[@"setMode(VoiceChat)"].doubleValue,
               self.stepMs[@"inputNumberOfChannels"].doubleValue,
               self.stepMs[@"outputNumberOfChannels"].doubleValue,
               self.stepMs[@"outputPort.isSpatialAudioEnabled"].doubleValue,
               self.stepMs[@"setPreferredSampleRate(48000)"].doubleValue,
               self.stepMs[@"setPreferredIOBufferDuration(0.01)"].doubleValue,
               self.stepMs[@"setPreferredInputNumberOfChannels(1)"].doubleValue,
               self.stepMs[@"setPreferredOutputNumberOfChannels(2)"].doubleValue,
               self.stepMs[@"setActive(YES)"].doubleValue,
               total > 1000.0, [self routeString]];
    [self log:@"SUMMARY wall_clock_since_config_start=%.1fms", sinceConfigStart];

    [self startCapture];
}

- (void)startCapture {
    NSError *error = nil;
    double start = NowMS();
    self.inputBufferCount = 0;
    self.firstInputBufferLogged = NO;

    self.inputEngine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = self.inputEngine.inputNode;
    AVAudioFormat *format = [input inputFormatForBus:0];
    __weak typeof(self) weakSelf = self;

    [input installTapOnBus:0
                bufferSize:480
                    format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        weakSelf.inputBufferCount += 1;
        if (!weakSelf.firstInputBufferLogged) {
            weakSelf.firstInputBufferLogged = YES;
            [weakSelf log:@"IMPACT mode=%@ first_input_buffer=%.1fms since_config_start=%.1fms frames=%u",
                       weakSelf.runMode, NowMS() - start,
                       NowMS() - weakSelf.configStart, buffer.frameLength];
        }
    }];

    BOOL ok = [self.inputEngine startAndReturnError:&error];
    [self log:@"CAPTURE start ok=%d elapsed=%.1fms error=%@",
               ok, NowMS() - start, error.localizedDescription];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf finishRun];
    });
}

- (void)finishRun {
    [self log:@"CAPTURE buffers=%ld first_buffer=%d",
               (long)self.inputBufferCount, self.firstInputBufferLogged];

    if (self.inputEngine) {
        [self.inputEngine.inputNode removeTapOnBus:0];
        [self.inputEngine stop];
        self.inputEngine = nil;
    }

    NSError *error = nil;
    os_signpost_id_t signpost = [self beginStep:@"cleanup.setActive(NO)"];
    double start = NowMS();
    BOOL ok = [self.session setActive:NO error:&error];
    [self endStep:@"cleanup.setActive(NO)" signpost:signpost start:start error:error
           detail:[NSString stringWithFormat:@"ok=%d", ok]];

    [self stopToneAndLog];
    [self log:@"RUN DONE mode=%@", self.runMode];
    self.running = NO;
}

@end
