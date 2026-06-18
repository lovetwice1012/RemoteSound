using System.Diagnostics;

namespace RemoteSound.WinForms;

internal sealed class MainForm : Form
{
    private readonly AppSettings _settings;
    private readonly AudioLoopbackCaptureService _captureService = new();
    private RemoteSoundWebSocketAudioServer? _server;
    private RemoteSoundHlsServer? _hlsServer;
    private RemoteSoundWebSocketClient? _client;
    private List<AudioDeviceInfo> _devices = [];
    private bool _isDisconnecting;

    private readonly ComboBox _serverUrlBox = new();
    private readonly TextBox _sourceNameBox = new();
    private readonly TextBox _clientIdBox = new();
    private readonly ComboBox _deviceBox = new();
    private readonly TrackBar _gainBar = new();
    private readonly Label _gainLabel = new();
    private readonly Label _statusLabel = new();
    private readonly LevelBar _levelBar = new();
    private readonly TextBox _logBox = new();
    private readonly ModernButton _connectButton = new();
    private readonly ModernButton _disconnectButton = new();
    private readonly CheckBox _autoReconnectBox = new();

    public MainForm()
    {
        _settings = SettingsStore.Load();
        Text = "RemoteSound Speaker Server";
        AutoScaleMode = AutoScaleMode.Dpi;
        MinimumSize = new Size(780, 640);
        Size = new Size(900, 700);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Color.FromArgb(18, 20, 28);
        Font = new Font("Segoe UI", 10f, FontStyle.Regular, GraphicsUnit.Point);
        DoubleBuffered = true;

        BuildUi();
        WireEvents();
        LoadSettingsIntoUi();
        RefreshDevices();
        SetConnected(false);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        NativeGlass.ApplyBackdrop(this);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        using var brush = new SolidBrush(Color.FromArgb(72, 10, 14, 24));
        e.Graphics.FillRectangle(brush, ClientRectangle);
        base.OnPaint(e);
    }

    protected override async void OnFormClosing(FormClosingEventArgs e)
    {
        SaveSettingsFromUi();
        SettingsStore.Save(_settings);
        await StopServerInternalAsync().ConfigureAwait(false);
        _captureService.Dispose();
        base.OnFormClosing(e);
    }

    private void BuildUi()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(20),
            RowCount = 4,
            ColumnCount = 1,
            BackColor = Color.Transparent,
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 72));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 276));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 120));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(root);

        var header = BuildHeader();
        root.Controls.Add(header, 0, 0);

        var settingsCard = new GlassPanel { Dock = DockStyle.Fill, Padding = new Padding(16), Margin = new Padding(0, 8, 0, 10) };
        root.Controls.Add(settingsCard, 0, 1);
        BuildSettingsCard(settingsCard);

        var statusCard = new GlassPanel { Dock = DockStyle.Fill, Padding = new Padding(16), Margin = new Padding(0, 0, 0, 10) };
        root.Controls.Add(statusCard, 0, 2);
        BuildStatusCard(statusCard);

        var logCard = new GlassPanel { Dock = DockStyle.Fill, Padding = new Padding(16), Margin = new Padding(0) };
        root.Controls.Add(logCard, 0, 3);
        BuildLogCard(logCard);
    }

    private Control BuildHeader()
    {
        var panel = new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent };
        panel.MouseDown += (_, _) => NativeGlass.DragWindow(this);

        var title = new Label
        {
            AutoSize = false,
            Text = "RemoteSound",
            ForeColor = Color.White,
            Font = new Font("Segoe UI Variable Display", 22f, FontStyle.Bold, GraphicsUnit.Point),
            Location = new Point(0, 4),
            Size = new Size(340, 36),
            BackColor = Color.Transparent,
        };
        title.MouseDown += (_, _) => NativeGlass.DragWindow(this);
        panel.Controls.Add(title);

        var subtitle = new Label
        {
            AutoSize = false,
            Text = "Windows speaker loopback server - 48 kHz stereo PCM",
            ForeColor = Color.FromArgb(190, 220, 230, 245),
            Location = new Point(2, 42),
            Size = new Size(480, 22),
            BackColor = Color.Transparent,
        };
        subtitle.MouseDown += (_, _) => NativeGlass.DragWindow(this);
        panel.Controls.Add(subtitle);

        var closeButton = HeaderButton("×");
        closeButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        closeButton.Location = new Point(Width - 74, 6);
        closeButton.Click += (_, _) => Close();
        panel.Controls.Add(closeButton);

        var minimizeButton = HeaderButton("—");
        minimizeButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        minimizeButton.Location = new Point(Width - 120, 6);
        minimizeButton.Click += (_, _) => WindowState = FormWindowState.Minimized;
        panel.Controls.Add(minimizeButton);

        panel.Resize += (_, _) =>
        {
            closeButton.Location = new Point(panel.Width - 44, 6);
            minimizeButton.Location = new Point(panel.Width - 90, 6);
        };

        return panel;
    }

    private static Button HeaderButton(string text)
    {
        return new Button
        {
            Text = text,
            Size = new Size(38, 32),
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(50, 255, 255, 255),
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 12f, FontStyle.Bold, GraphicsUnit.Point),
            Cursor = Cursors.Hand,
            TabStop = false,
        }.Also(button =>
        {
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.MouseOverBackColor = Color.FromArgb(86, 255, 255, 255);
            button.FlatAppearance.MouseDownBackColor = Color.FromArgb(120, 255, 255, 255);
        });
    }

    private void BuildSettingsCard(Control parent)
    {
        var grid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 4,
            RowCount = 5,
            BackColor = Color.Transparent,
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 140));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 132));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 132));
        for (var i = 0; i < 5; i++)
        {
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        }

        parent.Controls.Add(grid);

        AddLabel(grid, "Listen Port", 0, 0);
        StyleCombo(_serverUrlBox);
        _serverUrlBox.DropDownStyle = ComboBoxStyle.DropDown;
        grid.Controls.Add(_serverUrlBox, 1, 0);
        grid.SetColumnSpan(_serverUrlBox, 3);

        AddLabel(grid, "Source Name", 0, 1);
        StyleTextBox(_sourceNameBox);
        grid.Controls.Add(_sourceNameBox, 1, 1);
        grid.SetColumnSpan(_sourceNameBox, 3);

        AddLabel(grid, "Client ID", 0, 2);
        StyleTextBox(_clientIdBox);
        _clientIdBox.ReadOnly = false;
        grid.Controls.Add(_clientIdBox, 1, 2);
        grid.SetColumnSpan(_clientIdBox, 2);

        var newIdButton = new ModernButton { Text = "New ID", AccentColor = Color.FromArgb(75, 85, 99), Dock = DockStyle.Fill, Margin = new Padding(8, 2, 0, 4) };
        newIdButton.Click += (_, _) => _clientIdBox.Text = Guid.NewGuid().ToString();
        grid.Controls.Add(newIdButton, 3, 2);

        AddLabel(grid, "Speaker", 0, 3);
        StyleCombo(_deviceBox);
        _deviceBox.DropDownStyle = ComboBoxStyle.DropDownList;
        grid.Controls.Add(_deviceBox, 1, 3);
        grid.SetColumnSpan(_deviceBox, 2);

        var refreshButton = new ModernButton { Text = "Refresh", AccentColor = Color.FromArgb(75, 85, 99), Dock = DockStyle.Fill, Margin = new Padding(8, 2, 0, 4) };
        refreshButton.Click += (_, _) => RefreshDevices();
        grid.Controls.Add(refreshButton, 3, 3);

        AddLabel(grid, "Gain", 0, 4);
        _gainBar.Minimum = 0;
        _gainBar.Maximum = 300;
        _gainBar.TickFrequency = 50;
        _gainBar.SmallChange = 5;
        _gainBar.LargeChange = 10;
        _gainBar.Dock = DockStyle.Fill;
        _gainBar.BackColor = Color.FromArgb(28, 30, 38);
        _gainBar.ValueChanged += (_, _) =>
        {
            _gainLabel.Text = $"{_gainBar.Value}%";
            _captureService.Gain = _gainBar.Value / 100f;
        };
        grid.Controls.Add(_gainBar, 1, 4);
        grid.SetColumnSpan(_gainBar, 2);

        _gainLabel.TextAlign = ContentAlignment.MiddleRight;
        _gainLabel.ForeColor = Color.White;
        _gainLabel.Dock = DockStyle.Fill;
        grid.Controls.Add(_gainLabel, 3, 4);
    }

    private void BuildStatusCard(Control parent)
    {
        var grid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 5,
            RowCount = 2,
            BackColor = Color.Transparent,
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 20));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        parent.Controls.Add(grid);

        _statusLabel.Text = "Idle";
        _statusLabel.ForeColor = Color.FromArgb(225, 240, 245, 255);
        _statusLabel.Font = new Font("Segoe UI Semibold", 12f, FontStyle.Regular, GraphicsUnit.Point);
        _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
        _statusLabel.Dock = DockStyle.Fill;
        grid.Controls.Add(_statusLabel, 0, 0);

        _connectButton.Text = "Start";
        _connectButton.Dock = DockStyle.Fill;
        _connectButton.Margin = new Padding(8, 0, 0, 0);
        _connectButton.MinimumSize = new Size(0, 40);
        _connectButton.Click += async (_, _) => await StartServerInternalAsync().ConfigureAwait(false);
        grid.Controls.Add(_connectButton, 1, 0);

        _disconnectButton.Text = "Stop";
        _disconnectButton.AccentColor = Color.FromArgb(220, 86, 86);
        _disconnectButton.Dock = DockStyle.Fill;
        _disconnectButton.Margin = new Padding(8, 0, 0, 0);
        _disconnectButton.MinimumSize = new Size(0, 40);
        _disconnectButton.Click += async (_, _) => await StopServerInternalAsync().ConfigureAwait(false);
        grid.Controls.Add(_disconnectButton, 2, 0);

        _autoReconnectBox.Text = "Accept reconnects";
        _autoReconnectBox.ForeColor = Color.FromArgb(220, 240, 245, 255);
        _autoReconnectBox.BackColor = Color.Transparent;
        _autoReconnectBox.Dock = DockStyle.Fill;
        _autoReconnectBox.Checked = true;
        grid.Controls.Add(_autoReconnectBox, 4, 0);

        _levelBar.Dock = DockStyle.Fill;
        _levelBar.Margin = new Padding(0, 10, 0, 0);
        grid.Controls.Add(_levelBar, 0, 1);
        grid.SetColumnSpan(_levelBar, 5);
    }

    private void BuildLogCard(Control parent)
    {
        _logBox.Multiline = true;
        _logBox.ReadOnly = true;
        _logBox.BorderStyle = BorderStyle.None;
        _logBox.Dock = DockStyle.Fill;
        _logBox.ScrollBars = ScrollBars.Vertical;
        _logBox.BackColor = Color.FromArgb(24, 26, 34);
        _logBox.ForeColor = Color.FromArgb(220, 236, 242, 255);
        _logBox.Font = new Font("Cascadia Mono", 9.5f, FontStyle.Regular, GraphicsUnit.Point);
        parent.Controls.Add(_logBox);
    }

    private static void AddLabel(TableLayoutPanel grid, string text, int column, int row)
    {
        var label = new Label
        {
            Text = text,
            ForeColor = Color.FromArgb(190, 226, 232, 245),
            TextAlign = ContentAlignment.MiddleLeft,
            Dock = DockStyle.Fill,
            Font = new Font("Segoe UI Semibold", 10f, FontStyle.Regular, GraphicsUnit.Point),
        };
        grid.Controls.Add(label, column, row);
    }

    private static void StyleTextBox(TextBox box)
    {
        box.BorderStyle = BorderStyle.FixedSingle;
        box.BackColor = Color.FromArgb(36, 39, 50);
        box.ForeColor = Color.White;
        box.Font = new Font("Segoe UI", 10.5f, FontStyle.Regular, GraphicsUnit.Point);
        box.Dock = DockStyle.Fill;
        box.Margin = new Padding(0, 4, 0, 4);
    }

    private static void StyleCombo(ComboBox combo)
    {
        combo.FlatStyle = FlatStyle.Flat;
        combo.BackColor = Color.FromArgb(36, 39, 50);
        combo.ForeColor = Color.White;
        combo.Font = new Font("Segoe UI", 10.5f, FontStyle.Regular, GraphicsUnit.Point);
        combo.Dock = DockStyle.Fill;
        combo.Margin = new Padding(0, 4, 0, 4);
    }

    private void WireEvents()
    {
        _captureService.FrameReady += frame =>
        {
            _server?.TryQueueAudioFrame(frame);
            _hlsServer?.PushPcmFrame(frame);
        };
        _captureService.LevelChanged += level => BeginInvokeSafe(() => _levelBar.Value = level);
        _captureService.Log += AppendLog;
    }

    private void LoadSettingsIntoUi()
    {
        _serverUrlBox.Items.Clear();
        _serverUrlBox.Items.Add("8765");
        _serverUrlBox.Items.Add("8080");
        _serverUrlBox.Text = _settings.ListenPort.ToString();
        _sourceNameBox.Text = _settings.SourceName;
        _clientIdBox.Text = _settings.ClientId;
        _gainBar.Value = Math.Clamp(_settings.GainPercent, _gainBar.Minimum, _gainBar.Maximum);
        _gainLabel.Text = $"{_gainBar.Value}%";
        _autoReconnectBox.Checked = _settings.AutoReconnect;
    }

    private void SaveSettingsFromUi()
    {
        if (int.TryParse(_serverUrlBox.Text.Trim(), out var listenPort))
        {
            _settings.ListenPort = Math.Clamp(listenPort, 1_024, 65_535);
        }
        _settings.SourceName = _sourceNameBox.Text.Trim();
        _settings.ClientId = _clientIdBox.Text.Trim();
        _settings.GainPercent = _gainBar.Value;
        _settings.AutoReconnect = _autoReconnectBox.Checked;
        if (_deviceBox.SelectedItem is AudioDeviceInfo device)
        {
            _settings.LastRenderDeviceId = device.Id;
        }
    }

    private void RefreshDevices()
    {
        try
        {
            _devices = AudioLoopbackCaptureService.GetRenderDevices();
            _deviceBox.Items.Clear();
            foreach (var device in _devices)
            {
                _deviceBox.Items.Add(device);
            }

            var selected = _devices.FirstOrDefault(x => string.Equals(x.Id, _settings.LastRenderDeviceId, StringComparison.OrdinalIgnoreCase))
                ?? _devices.FirstOrDefault(x => x.IsDefault)
                ?? _devices.FirstOrDefault();

            if (selected is not null)
            {
                _deviceBox.SelectedItem = selected;
            }

            AppendLog($"Detected {_devices.Count} active render device(s).");
        }
        catch (Exception ex)
        {
            AppendLog("Device refresh failed: " + ex.Message);
        }
    }

    private async Task StartServerInternalAsync()
    {
        if (_server?.IsRunning == true)
        {
            return;
        }

        try
        {
            SaveSettingsFromUi();
            SettingsStore.Save(_settings);
            SetStatus("Starting ...");
            SetConnected(false, busy: true);

            if (!int.TryParse(_serverUrlBox.Text.Trim(), out var port) || port < 1_024 || port > 65_535)
            {
                throw new InvalidOperationException("Listen port must be between 1024 and 65535.");
            }
            _settings.ListenPort = port;

            var selectedDevice = _deviceBox.SelectedItem as AudioDeviceInfo;
            var server = new RemoteSoundWebSocketAudioServer();
            server.Log += AppendLog;
            server.ClientConnected += () => BeginInvokeSafe(() => SetStatus("iPhone connected - streaming speaker output"));
            server.ClientDisconnected += () => BeginInvokeSafe(() => SetStatus(_server?.IsRunning == true ? "Waiting for iPhone receiver" : "Idle"));
            _server = server;

            var hlsServer = new RemoteSoundHlsServer();
            hlsServer.Log += AppendLog;
            _hlsServer = hlsServer;

            await server.StartAsync(_settings.ListenPort, _settings.SourceName, _settings.ClientId, CancellationToken.None).ConfigureAwait(false);
            hlsServer.Start(_settings.ListenPort + 1);
            _captureService.Start(selectedDevice?.Id, _settings.Gain);

            BeginInvokeSafe(() =>
            {
                SetConnected(true);
                SetStatus("Waiting for iPhone receiver");
            });
        }
        catch (Exception ex)
        {
            AppendLog("Start failed: " + ex.Message);
            await StopServerInternalAsync().ConfigureAwait(false);
            BeginInvokeSafe(() =>
            {
                SetConnected(false);
                SetStatus("Start failed");
            });
        }
    }

    private async Task StopServerInternalAsync()
    {
        if (_isDisconnecting)
        {
            return;
        }

        _isDisconnecting = true;
        try
        {
            BeginInvokeSafe(() => SetStatus("Stopping ..."));
            _captureService.Stop();
            if (_server is not null)
            {
                await _server.DisposeAsync().ConfigureAwait(false);
                _server = null;
            }
            if (_hlsServer is not null)
            {
                _hlsServer.Dispose();
                _hlsServer = null;
            }
        }
        finally
        {
            _isDisconnecting = false;
            BeginInvokeSafe(() =>
            {
                _levelBar.Value = 0;
                SetConnected(false);
                SetStatus("Idle");
            });
        }
    }

    private async Task ConnectInternalAsync()
    {
        if (_client?.IsConnected == true)
        {
            return;
        }

        try
        {
            SaveSettingsFromUi();
            SettingsStore.Save(_settings);
            SetStatus("Connecting ...");
            SetConnected(false, busy: true);

            if (!Uri.TryCreate(_settings.ServerUrl, UriKind.Absolute, out var uri) || (uri.Scheme != "ws" && uri.Scheme != "wss"))
            {
                throw new InvalidOperationException("接続先は ws:// または wss:// の URL にしてください。");
            }

            var selectedDevice = _deviceBox.SelectedItem as AudioDeviceInfo;
            var client = new RemoteSoundWebSocketClient();
            client.Log += AppendLog;
            client.Disconnected += () => BeginInvokeSafe(async () => await HandleUnexpectedDisconnectAsync().ConfigureAwait(false));
            _client = client;

            await client.ConnectAsync(uri, _settings.SourceName, _settings.ClientId, CancellationToken.None).ConfigureAwait(false);
            _captureService.Start(selectedDevice?.Id, _settings.Gain);

            BeginInvokeSafe(() =>
            {
                ReloadRecentUrls();
                SetConnected(true);
                SetStatus("Streaming speaker output");
            });
        }
        catch (Exception ex)
        {
            AppendLog("Connect failed: " + ex.Message);
            await DisconnectInternalAsync().ConfigureAwait(false);
            BeginInvokeSafe(() =>
            {
                SetConnected(false);
                SetStatus("Connect failed");
            });
        }
    }

    private async Task DisconnectInternalAsync()
    {
        if (_isDisconnecting)
        {
            return;
        }

        _isDisconnecting = true;
        try
        {
            BeginInvokeSafe(() => SetStatus("Disconnecting ..."));
            _captureService.Stop();
            if (_client is not null)
            {
                await _client.DisposeAsync().ConfigureAwait(false);
                _client = null;
            }
        }
        finally
        {
            _isDisconnecting = false;
            BeginInvokeSafe(() =>
            {
                _levelBar.Value = 0;
                SetConnected(false);
                SetStatus("Idle");
            });
        }
    }

    private async Task HandleUnexpectedDisconnectAsync()
    {
        if (_isDisconnecting)
        {
            return;
        }

        AppendLog("Disconnected unexpectedly.");
        await DisconnectInternalAsync().ConfigureAwait(false);

        if (!_autoReconnectBox.Checked)
        {
            return;
        }

        AppendLog("Auto reconnect in 2 seconds ...");
        await Task.Delay(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        if (!IsDisposed && _autoReconnectBox.Checked)
        {
            await ConnectInternalAsync().ConfigureAwait(false);
        }
    }

    private void ReloadRecentUrls()
    {
        _serverUrlBox.Items.Clear();
        foreach (var url in _settings.RecentServerUrls)
        {
            _serverUrlBox.Items.Add(url);
        }
        _serverUrlBox.Text = _settings.ServerUrl;
    }

    private void SetConnected(bool connected, bool busy = false)
    {
        _connectButton.Enabled = !connected && !busy;
        _disconnectButton.Enabled = connected || busy;
        _serverUrlBox.Enabled = !connected && !busy;
        _deviceBox.Enabled = !connected && !busy;
        _sourceNameBox.Enabled = !connected && !busy;
        _clientIdBox.Enabled = !connected && !busy;
    }

    private void SetStatus(string status)
    {
        _statusLabel.Text = status;
    }

    private void AppendLog(string message)
    {
        BeginInvokeSafe(() =>
        {
            var line = $"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}";
            _logBox.AppendText(line);
            if (_logBox.TextLength > 80_000)
            {
                _logBox.Text = _logBox.Text[^40_000..];
                _logBox.SelectionStart = _logBox.TextLength;
            }
        });
    }

    private void BeginInvokeSafe(Action action)
    {
        if (IsDisposed)
        {
            return;
        }

        try
        {
            if (InvokeRequired)
            {
                BeginInvoke(action);
            }
            else
            {
                action();
            }
        }
        catch (ObjectDisposedException)
        {
        }
        catch (InvalidOperationException)
        {
        }
    }
}

internal static class ObjectExtensions
{
    public static T Also<T>(this T value, Action<T> action)
    {
        action(value);
        return value;
    }
}
