using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using PixelBooth.Core.Capture;
using PixelBooth.Core.Imaging;
using PixelBooth.Core.Storage;
using Windows.Graphics.Imaging;
using Windows.Security.Cryptography;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;
using Windows.System;
using WinRT.Interop;

namespace PixelBooth;

public sealed partial class MainWindow : Window
{
    private readonly Settings _settings = Settings.Load();
    private readonly CaptureStore _store = new();
    private readonly SemaphoreSlim _configuration = new(1, 1);
    private readonly object _frameLock = new();
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _statusTimer;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _saveOverlayTimer;
    private CancellationTokenSource? _streamCancel;
    private Task? _streamTask;
    private CameraFrame? _latest;
    private TaskCompletionSource<CameraFrame>? _nextIdr;
    private TaskCompletionSource<CameraControlSnapshot>? _controlRequest;
    private CameraDevice? _device;
    private CameraMode? _mode;
    private CameraMode[] _availableModes = [];
    private long _generation;
    private long _streamStart;
    private int _frameCount;
    private int _previewBusy;
    private string _details = "No camera selected.";
    private bool _capturing;
    private bool _closed;
    private int _saving;

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 820));
        MirrorMenuItem.IsChecked = _settings.Mirror;
        PreviewTransform.ScaleX = _settings.Mirror ? -1 : 1;
        UpdateTimerMenu();
        PopulateCameraMenu([]);
        SetAvailableModes([]);
        _saveOverlayTimer = DispatcherQueue.CreateTimer();
        _saveOverlayTimer.Interval = TimeSpan.FromSeconds(5);
        _saveOverlayTimer.IsRepeating = false;
        _saveOverlayTimer.Tick += (_, _) => SaveOverlay.Visibility = Visibility.Collapsed;
        _statusTimer = DispatcherQueue.CreateTimer();
        _statusTimer.Interval = TimeSpan.FromMilliseconds(250);
        _statusTimer.Tick += (_, _) => UpdateReadiness();
        _statusTimer.Start();
        Root.KeyDown += Root_KeyDown;
        Closed += Window_Closed;
        Root.Loaded += async (_, _) => { UpdatePendingStatus(); await RefreshCamerasAsync(); };
    }

    private async Task RefreshCamerasAsync()
    {
        try
        {
            ReadyText.Text = "Looking for cameras…";
            var cameras = await Task.Run(MediaFoundationCamera.Discover);
            if (_closed) return;
            var wanted = _device?.Id ?? _settings.CameraId;
            var selected = wanted is null ? cameras.FirstOrDefault() : cameras.FirstOrDefault(c => c.Id == wanted);
            PopulateCameraMenu(cameras, selected);
            if (selected is null)
            {
                _device = null;
                _mode = null;
                SetAvailableModes([]);
                _details = "No camera selected.";
                await ConfigureAsync(true);
                ReadyText.Text = cameras.Count == 0 ? "No camera found. Connect a camera and refresh." : "The previously selected camera is unavailable. Choose a camera.";
            }
            else { _device = selected; await ConfigureAsync(true); }
        }
        catch (Exception e) { ReadyText.Text = $"Could not discover cameras: {e.Message}"; }
    }

    private async Task ConfigureAsync(bool chooseMode)
    {
        var revision = Interlocked.Increment(ref _generation);
        _streamCancel?.Cancel();
        lock (_frameLock)
        {
            _latest = null; _frameCount = 0; _nextIdr?.TrySetCanceled(); _nextIdr = null;
            _controlRequest?.TrySetCanceled(); _controlRequest = null;
        }
        Shutter.IsEnabled = false;
        ReadyText.Text = "Starting camera…";
        Preview.Source = null;
        PreviewMessage.Text = "Starting camera…";
        PreviewMessage.Visibility = Visibility.Visible;
        await _configuration.WaitAsync();
        try
        {
            if (_streamTask is not null)
            {
                try { await _streamTask.WaitAsync(TimeSpan.FromSeconds(8)); }
                catch (TimeoutException) { ReadyText.Text = "The previous camera is not responding. Close and reopen PixelBooth."; return; }
                _streamTask = null;
                _streamCancel?.Dispose();
                _streamCancel = null;
            }
            if (_closed || revision != _generation) return;
            if (_device is null)
            {
                PreviewMessage.Text = "Choose a camera from the Capture menu";
                return;
            }
            var device = _device;
            if (chooseMode)
            {
                var modes = await Task.Run(() => { using var camera = new MediaFoundationCamera(); return camera.Open(device).ToArray(); });
                if (_closed || revision != _generation) return;
                var ordered = modes.OrderByDescending(m => (long)m.Width * m.Height).ThenByDescending(m => m.Width)
                    .ThenByDescending(m => m.FourCC is "NV12" or "YUY2" ? 2 : m.IsMjpeg ? 1 : 0)
                    .ThenByDescending(m => m.FramesPerSecond).ToArray();
                if (_settings.Modes.TryGetValue(device.Id, out var saved))
                {
                    _mode = ordered.FirstOrDefault(m => m.Id == saved);
                    if (_mode is null) ReadyText.Text = "The previously selected format is unavailable. Choose a camera format.";
                }
                else _mode = ordered.FirstOrDefault(m => UnsupportedReason(m) is null);
                SetAvailableModes(ordered);
            }
            if (_mode is null) { _details = $"Device: {device.Name}\nNo capture format selected."; if (string.IsNullOrEmpty(ReadyText.Text) || ReadyText.Text == "Starting camera…") ReadyText.Text = "Choose an available camera format."; return; }
            var mode = _mode;
            var unsupported = UnsupportedReason(mode);
            if (unsupported is not null)
            {
                _details = $"Device: {device.Name}\nSelected: {mode}\nCannot preserve this format: {unsupported}";
                ReadyText.Text = $"Choose another format: {unsupported}";
                PreviewMessage.Text = "This format cannot be preserved faithfully yet.";
                return;
            }
            _streamCancel = new CancellationTokenSource();
            var token = _streamCancel.Token;
            _details = $"Device: {device.Name}\nSelected: {mode}\nDelivered: Windows Media Foundation source-reader samples\nPreservation boundary: Windows Media Foundation delivered; driver processing is unknown.\nOutput: {(mode.IsMjpeg ? "JPEG, without recompression" : mode.IsH264 ? "AVCI, one independently decodable IDR picture" : LosslessTiff.RequiresTiff(mode) ? "Lossless TIFF with sample verification" : "AVIF, lossless YCbCr with sample verification")}\nColor matrix: {Describe(mode.Matrix)} · range: {Describe(mode.NominalRange)} · chroma siting: {Describe(mode.ChromaSiting)}\nSystem camera effects: unknown";
            if (mode.FourCC == "YUY2") _details += "\nOutput chroma: co-sited (PixelBooth YUY2 policy; reported flag retained in metadata).";
            _streamTask = Task.Run(() => RunStream(device, mode, revision, token));
        }
        catch (Exception e) { if (!_closed && revision == _generation) ReadyText.Text = $"Could not start camera: {e.Message}"; }
        finally { _configuration.Release(); }
    }

    private void RunStream(CameraDevice device, CameraMode mode, long revision, CancellationToken token)
    {
        try
        {
            using var camera = new MediaFoundationCamera();
            var available = camera.Open(device);
            var requested = available.FirstOrDefault(m => m.Id == mode.Id) ?? throw new InvalidOperationException("The selected mode disappeared.");
            var selected = camera.SetMode(requested);
            using var h264Decoder = mode.IsH264 ? new H264PreviewDecoder(mode.Width, mode.Height) : null;
            var collector = mode.IsH264 ? new H264AccessUnitCollector() : null;
            if (collector is not null && selected.SequenceHeader is { Length: > 0 }) collector.Observe(selected.SequenceHeader);
            var prependHeader = selected.SequenceHeader is { Length: > 0 };
            var start = Stopwatch.GetTimestamp();
            while (!token.IsCancellationRequested)
            {
                var frame = camera.Read(device, selected, revision);
                if (token.IsCancellationRequested || frame is null) continue;
                TaskCompletionSource<CameraControlSnapshot>? controlRequest;
                lock (_frameLock) { controlRequest = _controlRequest; _controlRequest = null; }
                if (controlRequest is not null)
                {
                    var started = DateTimeOffset.Now;
                    try { controlRequest.TrySetResult(camera.ReadControls()); }
                    catch (Exception e)
                    {
                        controlRequest.TrySetResult(new(started, DateTimeOffset.Now, [],
                            $"Control read failed: {e.GetType().Name} (0x{e.HResult:X8})"));
                    }
                }
                byte[]? decoded = null;
                if (collector is not null && h264Decoder is not null)
                {
                    var picture = collector.Observe(frame.Bytes);
                    if (picture is not null && picture.Width == selected.Width && picture.Height == selected.Height)
                    {
                        var captureFrame = frame with { CodecHeader = picture.CodecHeader };
                        lock (_frameLock) { _nextIdr?.TrySetResult(captureFrame); _nextIdr = null; }
                    }
                    var input = prependHeader ? selected.SequenceHeader!.Concat(frame.Bytes).ToArray() : frame.Bytes;
                    prependHeader = false;
                    decoded = h264Decoder.Decode(input, frame.MediaTimestamp100ns);
                }
                lock (_frameLock) { _latest = frame; _streamStart = start; _frameCount++; }
                if (!mode.IsH264 || decoded is not null) QueuePreview(frame, decoded);
            }
        }
        catch (Exception e)
        {
            lock (_frameLock)
            {
                _latest = null; _nextIdr?.TrySetException(e); _nextIdr = null;
                _controlRequest?.TrySetException(e); _controlRequest = null;
            }
            if (!token.IsCancellationRequested) DispatcherQueue.TryEnqueue(() =>
            {
                if (!_closed && revision == _generation)
                {
                    ReadyText.Text = $"Camera stopped: {e.Message}";
                    PreviewMessage.Text = "Camera unavailable";
                    PreviewMessage.Visibility = Visibility.Visible;
                    Shutter.IsEnabled = false;
                }
            });
        }
    }

    private void QueuePreview(CameraFrame frame, byte[]? decoded)
    {
        // Keep at most one display frame in flight; acquisition never waits for preview conversion.
        if (Interlocked.CompareExchange(ref _previewBusy, 1, 0) != 0) return;
        _ = Task.Run(() =>
        {
            try
            {
                var previewFrame = decoded is null ? frame : frame with { Bytes = decoded, Mode = frame.Mode with { FourCC = "NV12", InterlaceMode = 2 } };
                var pixels = frame.Mode.IsMjpeg ? null : PreviewPixels.ToBgra(previewFrame);
                if (!DispatcherQueue.TryEnqueue(async () => await ShowPreviewAsync(frame, pixels)))
                    Interlocked.Exchange(ref _previewBusy, 0);
            }
            catch { Interlocked.Exchange(ref _previewBusy, 0); }
        });
    }

    private async Task ShowPreviewAsync(CameraFrame frame, byte[]? pixels)
    {
        try
        {
            if (_closed || frame.Generation != _generation) return;
            if (pixels is null)
            {
                using var stream = new InMemoryRandomAccessStream();
                using var writer = new DataWriter(stream.GetOutputStreamAt(0));
                writer.WriteBytes(frame.Bytes);
                await writer.StoreAsync();
                await writer.FlushAsync();
                var image = new BitmapImage();
                await image.SetSourceAsync(stream);
                if (!_closed && frame.Generation == _generation) Preview.Source = image;
            }
            else
            {
                using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(CryptographicBuffer.CreateFromByteArray(pixels), BitmapPixelFormat.Bgra8,
                    frame.Mode.Width, frame.Mode.Height, BitmapAlphaMode.Ignore);
                var source = new SoftwareBitmapSource();
                await source.SetBitmapAsync(bitmap);
                if (!_closed && frame.Generation == _generation) Preview.Source = source;
            }
            if (!_closed && frame.Generation == _generation) PreviewMessage.Visibility = Visibility.Collapsed;
        }
        catch (Exception e) { if (!_closed && frame.Generation == _generation) { PreviewMessage.Text = $"Preview unavailable: {e.Message}"; PreviewMessage.Visibility = Visibility.Visible; } }
        finally { Interlocked.Exchange(ref _previewBusy, 0); }
    }

    private void UpdateReadiness()
    {
        CameraFrame? frame; int count; long start;
        lock (_frameLock) { frame = _latest; count = _frameCount; start = _streamStart; }
        if (frame is null || frame.Generation != _generation) { Shutter.IsEnabled = false; return; }
        var maxAge = Math.Max(0.5, frame.Mode.FramesPerSecond > 0 ? 2.0 / frame.Mode.FramesPerSecond : 0.5);
        var fresh = Stopwatch.GetElapsedTime(frame.MonotonicTimestamp).TotalSeconds <= maxAge;
        var ready = count >= 8 && Stopwatch.GetElapsedTime(start).TotalMilliseconds >= 500;
        Shutter.IsEnabled = fresh && ready && !_capturing;
        ReadyText.Text = !fresh ? "Waiting for a fresh camera frame…" : !ready ? "Warming up camera (heuristic)…" : "Ready";
    }

    private async Task CaptureAsync()
    {
        if (!Shutter.IsEnabled || _capturing) return;
        _capturing = true;
        var revision = _generation;
        UpdateReadiness();
        try
        {
            for (var remaining = _settings.Countdown; remaining > 0; remaining--)
            {
                CountdownBadge.Visibility = Visibility.Visible;
                CountdownLabel.Text = remaining.ToString();
                await Task.Delay(1000);
                if (_closed || revision != _generation) return;
            }
            CameraFrame? frame;
            lock (_frameLock) frame = _latest;
            var maxAge = frame?.Mode.FramesPerSecond > 0 ? Math.Max(0.5, 2.0 / frame.Mode.FramesPerSecond) : 0.5;
            if (frame is null || frame.Generation != revision || Stopwatch.GetElapsedTime(frame.MonotonicTimestamp).TotalSeconds > maxAge)
                throw new InvalidOperationException("No fresh camera frame is available.");
            if (frame.Mode.IsH264)
            {
                var waiter = new TaskCompletionSource<CameraFrame>(TaskCreationOptions.RunContinuationsAsynchronously);
                lock (_frameLock) _nextIdr = waiter;
                SetSaveStatus("Waiting for the next independently decodable H.264 picture…");
                try { frame = await waiter.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
                catch (TimeoutException) { throw new InvalidOperationException("The camera did not deliver an IDR picture within 10 seconds."); }
                finally { lock (_frameLock) if (ReferenceEquals(_nextIdr, waiter)) _nextIdr = null; }
                if (_closed || revision != _generation) return;
            }
            SetSaveStatus("Capturing locally…");
            frame = frame with { Controls = await ReadControlsNearShutterAsync(revision) };
            var pending = await _store.EnqueueAsync(frame, _settings.Destination);
            SetSaveStatus("Captured locally · saving…");
            _ = SavePendingAsync(pending);
        }
        catch (Exception e) { SetSaveStatus($"Capture failed: {e.Message}"); UpdatePendingStatus(false); }
        finally { CountdownBadge.Visibility = Visibility.Collapsed; _capturing = false; UpdateReadiness(); }
    }

    private async Task<CameraControlSnapshot> ReadControlsNearShutterAsync(long revision)
    {
        var requestedAt = DateTimeOffset.Now;
        var waiter = new TaskCompletionSource<CameraControlSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_frameLock)
        {
            if (!_closed && revision == _generation && _latest is not null)
                _controlRequest = waiter;
            else waiter.TrySetCanceled();
        }
        try { return await waiter.Task.WaitAsync(TimeSpan.FromSeconds(2)); }
        catch (TimeoutException) { return new(requestedAt, DateTimeOffset.Now, [], "Control read timed out"); }
        catch (OperationCanceledException) { return new(requestedAt, DateTimeOffset.Now, [], "Camera changed before control read"); }
        catch (Exception) { return new(requestedAt, DateTimeOffset.Now, [], "Control read failed"); }
        finally { lock (_frameLock) if (ReferenceEquals(_controlRequest, waiter)) _controlRequest = null; }
    }

    private async Task SavePendingAsync(PendingCapture capture)
    {
        _saving++;
        try
        {
            var saved = await Task.Run(() => _store.SaveAsync(capture));
            if (!_closed)
            {
                var controlStatus = capture.Controls is null ? "" : capture.Controls.Values.Length == 0
                    ? " · camera controls unavailable" : $" · {capture.Controls.Values.Length} camera-control observations";
                var sidecarStatus = File.Exists(Path.ChangeExtension(saved, ".xmp")) ? " · metadata in XMP sidecar" : "";
                SetSaveStatus($"Saved {Path.GetFileName(saved)}{controlStatus}{sidecarStatus}", transient: true);
            }
        }
        catch (Exception e) { if (!_closed) SetSaveStatus($"Saved locally for recovery: {e.Message}"); }
        finally { _saving--; if (!_closed) UpdatePendingStatus(false); }
    }

    private void SetSaveStatus(string message, bool transient = false)
    {
        _saveOverlayTimer.Stop();
        SaveStatus.Text = message;
        SaveOverlay.Visibility = Visibility.Visible;
        if (transient) _saveOverlayTimer.Start();
    }

    private void UpdatePendingStatus(bool updateText = true)
    {
        var count = _store.Pending().Count;
        var retained = _store.RetainedDirectoryCount;
        RetryButton.Visibility = count > 0 && _saving == 0 ? Visibility.Visible : Visibility.Collapsed;
        RecoveryFolderButton.Visibility = retained > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (count > 0 && _saving == 0)
        {
            _saveOverlayTimer.Stop();
            SaveOverlay.Visibility = Visibility.Visible;
        }
        if (retained > count) SetSaveStatus($"{retained - count} recovery item(s) need manual attention. Open the recovery folder.");
        else if (updateText && count > 0) SetSaveStatus($"{count} locally retained capture(s) need saving.");
    }

    private static string? UnsupportedReason(CameraMode mode)
    {
        if (mode.IsMjpeg || mode.IsH264) return null;
        if (!mode.IsRaw) return $"{mode.FourCC} is not supported.";
        try
        {
            if (LosslessTiff.RequiresTiff(mode)) LosslessTiff.ValidateMode(mode);
            else AvifEncoder.ValidateMode(mode);
            return null;
        }
        catch (InvalidDataException e) { return e.Message; }
    }
    private static string Describe(int? value) => value?.ToString() ?? "unknown";
    private void PersistSettings() { try { _settings.Save(); } catch (Exception e) { SetSaveStatus($"Settings could not be saved: {e.Message}"); } }
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshCamerasAsync();
    private void PopulateCameraMenu(IEnumerable<CameraDevice> cameras, CameraDevice? selected = null)
    {
        CameraMenu.Items.Clear();
        foreach (var device in cameras)
        {
            var item = new ToggleMenuFlyoutItem { Text = device.Name, IsChecked = device.Id == selected?.Id };
            item.Click += async (_, _) =>
            {
                _device = device;
                _mode = null;
                _settings.CameraId = device.Id;
                PersistSettings();
                foreach (var entry in CameraMenu.Items.OfType<ToggleMenuFlyoutItem>()) entry.IsChecked = entry == item;
                SetAvailableModes([]);
                await ConfigureAsync(true);
            };
            CameraMenu.Items.Add(item);
        }
        if (CameraMenu.Items.Count == 0) CameraMenu.Items.Add(new MenuFlyoutItem { Text = "No cameras found", IsEnabled = false });
    }

    private void SetAvailableModes(CameraMode[] modes)
    {
        _availableModes = modes;
        ModeMenuItem.IsEnabled = modes.Length > 0;
    }

    private async void Mode_Click(object sender, RoutedEventArgs e)
    {
        if (_device is null || _availableModes.Length == 0) return;
        var deviceId = _device.Id;
        var generation = _generation;
        var list = new ListView
        {
            ItemsSource = _availableModes,
            SelectionMode = ListViewSelectionMode.Single,
            SelectedItem = _availableModes.FirstOrDefault(mode => mode.Id == _mode?.Id),
            Height = 400,
            MinWidth = 400
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(list, "Available capture formats");
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "Capture format",
            Content = list,
            PrimaryButtonText = "Select",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = list.SelectedItem is not null
        };
        list.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = list.SelectedItem is not null;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not CameraMode mode) return;
        if (_closed || _device?.Id != deviceId || _generation != generation) return;
        if (_mode?.Id == mode.Id) return;
        _mode = mode;
        _settings.Modes[deviceId] = mode.Id;
        PersistSettings();
        await ConfigureAsync(false);
    }

    private void Mirror_Click(object sender, RoutedEventArgs e)
    {
        _settings.Mirror = MirrorMenuItem.IsChecked;
        PreviewTransform.ScaleX = _settings.Mirror ? -1 : 1;
        PersistSettings();
    }

    private void UpdateTimerMenu()
    {
        TimerOff.IsChecked = _settings.Countdown == 0;
        Timer3.IsChecked = _settings.Countdown == 3;
        Timer10.IsChecked = _settings.Countdown == 10;
    }

    private void Timer_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleMenuFlyoutItem item) return;
        _settings.Countdown = int.Parse((string)item.Tag);
        UpdateTimerMenu();
        PersistSettings();
    }

    private async void Details_Click(object sender, RoutedEventArgs e)
    {
        var details = new TextBlock { Text = $"{_details}\nSave folder: {_settings.Destination}", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "Capture details",
            Content = new ScrollViewer { Content = details, MaxHeight = 450, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            CloseButtonText = "Close"
        };
        await dialog.ShowAsync();
    }
    private async void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new FolderPicker(); picker.FileTypeFilter.Add("*"); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            var folder = await picker.PickSingleFolderAsync();
            if (folder is not null) { _settings.Destination = folder.Path; PersistSettings(); }
        }
        catch (Exception ex) { SetSaveStatus($"Could not choose a folder: {ex.Message}"); }
    }
    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        try { Directory.CreateDirectory(_settings.Destination); Process.Start(new ProcessStartInfo("explorer.exe", _settings.Destination) { UseShellExecute = true }); }
        catch (Exception ex) { SetSaveStatus($"Could not open folder: {ex.Message}"); }
    }
    private void OpenRecoveryFolder_Click(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", _store.Root) { UseShellExecute = true }); }
        catch (Exception ex) { SetSaveStatus($"Could not open the recovery folder: {ex.Message}"); }
    }
    private async void Retry_Click(object sender, RoutedEventArgs e)
    {
        RetryButton.Visibility = Visibility.Collapsed;
        foreach (var capture in _store.Pending()) await SavePendingAsync(capture with { Destination = _settings.Destination });
    }
    private async void Shutter_Click(object sender, RoutedEventArgs e) => await CaptureAsync();
    private async void Root_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Space && e.OriginalSource is not (Button or ComboBox or ToggleSwitch or TextBox or MenuFlyoutItem)) { e.Handled = true; await CaptureAsync(); }
    }
    private void Window_Closed(object sender, WindowEventArgs args)
    {
        _closed = true; Interlocked.Increment(ref _generation); _statusTimer.Stop(); _saveOverlayTimer.Stop(); _streamCancel?.Cancel();
        lock (_frameLock)
        {
            _nextIdr?.TrySetCanceled(); _nextIdr = null;
            _controlRequest?.TrySetCanceled(); _controlRequest = null;
        }
    }
}
