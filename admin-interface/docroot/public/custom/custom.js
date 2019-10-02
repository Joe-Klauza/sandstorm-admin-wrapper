var touchDevice = (navigator.maxTouchPoints || 'ontouchstart' in document.documentElement);
if (touchDevice) {
  var tooltipTrigger = 'hover click'
} else {
  var tooltipTrigger = 'hover'
}

// var user_scrolled_tailing_log = false;
var server_log_active = false;
var server_log_uuid = null;
var server_rcon_log_active = false;
var rcon_log_uuid = null;

var log_buffer_size = 500;
var server_log_tail_interval = 1000;
var server_status_interval = 1000;

var updatePlayersInterval = null;
var updateThreadsInterval = null;
var updateMonitoringDetailsInterval = null;

var tailBufferUuids = [];
var tailBufferStopUuids = [];

$(document).ready(function() {
  $(() => {
    $('[data-toggle="tooltip"]').tooltip({ trigger : tooltipTrigger, container : 'body' })
  });

  // TO DO - abstract to all log elements; use element attribute to track scrolled state
  // if ($('#tailing-log').length) {
  //   target = $('#tailing-log');
  //   target[0].scrollTop = target[0].scrollHeight;
  //   $('#tailing-log').animate({ scrollTop: "300px" });
  //   $('#tailing-log').bind('mousedown wheel DOMMouseScroll mousewheel keyup', function(e){
  //       window.user_scrolled_tailing_log = true;
  //   });
  // }

  if ($('#server-control-status').length) {
    setTimeout(()=>{ updateServerControlStatus(); }, 0); // Recursive
  }

  if ($('#server-monitor-configs').length) {
    setTimeout(()=>{ loadMonitorConfigs('#server-monitor-configs'); }, 0);
  }

  if ($('#active-server-monitors').length) {
    setTimeout(()=>{ loadActiveMonitors('#active-server-monitors'); }, 0);
  }

  if ($('#server-update-info').length) {
    setTimeout(updateServerUpdateInfo, 1);
    setInterval(updateServerUpdateInfo, 30000);
  }

  $('#confirm_modal').on('show.bs.modal', function() {
    var modalParent = $("#region_modal");
    $(modalParent).css('opacity', 0);
  }).on('hidden.bs.modal', function (){
    var modalParent = $("#region_modal");
    $(modalParent).css('opacity', 1);
  });

});

function deleteMonitorConfig(name) {
  $.ajax({
    url: `/monitor-config/${encodeURIComponent(name)}`,
    type: 'DELETE',
    success: function(message) {
      successToast(message);
      loadMonitorConfigs('#server-monitor-configs');
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function loadMonitorConfig(name) {
  $.get(`/monitor-config?name=${encodeURIComponent(name)}`, function(data) {
    data = JSON.parse(data);
    $('#name').val(name);
    $('#ip').val(data['ip']);
    $('#query_port').val(data['query_port']);
    $('#rcon_port').val(data['rcon_port']);
    $('#rcon_password').val(data['rcon_password']);
    $('#server-monitor').html('');
    monitorButtonStart();
  });
}

function monitorButtonStart() {
  $('#start-stop-monitor').html('Start Monitor');
  $('#start-stop-monitor').addClass('btn-success');
  $('#start-stop-monitor').removeClass('btn-warning');
}

function monitorButtonStop() {
  $('#start-stop-monitor').html('Stop Monitor');
  $('#start-stop-monitor').removeClass('btn-success');
  $('#start-stop-monitor').addClass('btn-warning');
}

function startMonitoringDetailsInterval(ip, rcon_port, element) {
  clearInterval(updateMonitoringDetailsInterval);
  setTimeout(() => { updateMonitoringDetails(ip, rcon_port, element); }, 750);
  updateMonitoringDetailsInterval = setInterval(() => { updateMonitoringDetails(ip, rcon_port, element); }, 2000);
  startRemoteRconTail(ip, rcon_port);
}

function loadActiveMonitors(element) {
  if (typeof element === 'undefined') {
    element = "#active-server-monitors"
  }
  $.get('/monitors', function(data) { $(element).html(data); });
}

function loadMonitorConfigs(element) {
  $.get('/monitor-configs', function(data) { $(element).html(data); });
}

function toggleMonitor(name, ip, query_port, rcon_port, rcon_password) {
  if ($('#start-stop-monitor').html() === 'Start Monitor') {
    startMonitor(name, ip, query_port, rcon_port, rcon_password);
  } else {
    stopMonitor(ip, rcon_port);
  }
}

function updateMonitoringDetails(ip, rcon_port, element) {
  if (typeof element === 'undefined') {
    element = '#monitoring-details'
  }
  $.get(`/monitoring-details/${ip}/${rcon_port}`, function(data){ $(element).html(data); });
}

function startRemoteRconTail(ip, rcon_port) {
  tailBufferStopUuids = tailBufferUuids
  tailBufferUuids = []
  $.get(`/monitor/${ip}/${rcon_port}`, (rcon_buffer_uuid)=>{ tailBufferUuids.push(rcon_buffer_uuid); tailBuffer('#rcon-log', 1000, rcon_buffer_uuid); });
}

function startMonitor(name, ip, query_port, rcon_port, rcon_password) {
  $.ajax({
    url: '/monitor/start',
    type: 'POST',
    contentType: "application/json",
    data: JSON.stringify({config: {name: name, ip: ip, query_port: query_port, rcon_port: rcon_port, rcon_password: rcon_password}}),
    success: function(message) {
      successToast(message);
      monitorButtonStop();
      startMonitoringDetailsInterval(ip, rcon_port);
      loadActiveMonitors();
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
      monitorButtonStop();
      startMonitoringDetailsInterval(ip, rcon_port);
      loadActiveMonitors();
    }
  });
}

function stopMonitor(ip, rcon_port) {
  $.ajax({
    url: '/monitor/stop',
    type: 'POST',
    contentType: "application/json",
    data: JSON.stringify({config: {ip: ip, rcon_port: rcon_port}}),
    success: function(message) {
      successToast(message);
      monitorButtonStart();
      clearInterval(updateMonitoringDetailsInterval);
      loadActiveMonitors();
      $('#monitoring-details').html('');
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
      monitorButtonStart();
      clearInterval(updateMonitoringDetailsInterval);
      loadActiveMonitors();
      $('#monitoring-details').html('');
    }
  });
}

function saveMonitorConfig(name, ip, query_port, rcon_port, rcon_password) {
  $.ajax({
    url: `/monitor-config/${name}`,
    type: 'POST',
    contentType: "application/json",
    data: JSON.stringify({config: {ip: ip, query_port: query_port, rcon_port: rcon_port, rcon_password: rcon_password}}),
    success: function(message) {
      successToast(message);
      loadMonitorConfigs('#server-monitor-configs');
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function loadServerConfigs(element) {
  $.get('/server-configs', function(data) { $(element || '#server-configs').html(data); });
}

function loadActiveServers(element) {
  if (typeof element === 'undefined') {
    element = "#active-servers"
  }
  $.get('/daemons', function(data) {
    $(element).html(data);
  });
}

function loadActiveServerConfig(game_port) {
  $.get(`/daemon/${game_port}`, (data) => {
    if ($('#server-status').length) {
      window.location.href = '/control';
      return;
    }
  });
}

function loadServerConfig(name) {
  $.get(`/server-config/${encodeURIComponent(name)}`, function(data) {
    if ($('#server-status').length) {
      window.location.href = '/control';
      return;
    }
    config = JSON.parse(data);
    $.each(config, (key, val) => {
      console.log(`${key} => ${val}`);
      if (key === 'server_mutators')
      {
        $('.server-config-mutator-input').each((i, el) => { el.checked = false });
        $.each(val, (i, mutator) => {
          $(`#server_mutator_${mutator}`)[0].checked = true;
        });
        setMutatorCount();
        return;
      }
      var element = $(`#${key}`)
      if (element.length) {
        if (element.hasClass('server-config-text-input')) {
          element.attr('placeholder', val);
          element.attr('previous', '');
          element.val('');
        } else if (element.hasClass('server-config-checkbox-input')) {
          element[0].checked = val
        } else {
          console.log("Unhandled loadServerConfig type: " + key);
        }
      }
    })
    loadServerConfigFileContent(name);
  });
}

function saveServerConfig() {
  var config = {};
  $('.server-config-text-input').each((index, element) => {
    var val = $(element).val() || $(element).attr('placeholder');
    if (val) {
      config[element.id] = val
    }
  });
  $('.server-config-checkbox-input').each((index, element)=>{
    config[element.id] = element.checked
  });
  var mutators = []
  $('.server-config-mutator-input').each((index, element) =>{
    if (element.checked) {
      mutators.push(element.getAttribute('mutator-key'));
    }
  });
  config['server_mutators'] = mutators
  var name = $('#server-config-name').val() || $('#server-config-name').attr('placeholder');
  writeConfigFiles(name);
  $.ajax({
    url: `/server-config/${encodeURIComponent(name)}`,
    type: 'POST',
    contentType: "application/json",
    data: JSON.stringify(config),
    success: function(message) {
      successToast(message);
      loadServerConfig(name);
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function deleteServerConfig(name) {
  $.ajax({
    url: `/server-config/${encodeURIComponent(name)}`,
    type: 'DELETE',
    success: function(message) {
      successToast(message);
      loadServerConfigs('#server-configs');
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function createUser(name, role) {
  $.ajax({
    url: '/wrapper-users/create',
    type: 'POST',
    contentType: "application/json",
    data: JSON.stringify({name: name, role: role}),
    success: function(message) {
      successToast(message);
      $.get('/wrapper-users-list', function(data) { $('#users').html(data); });
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function deleteUser(id) {
  $.ajax({
    url: '/wrapper-users/delete',
    type: 'POST',
    contentType: "application/json",
    data: JSON.stringify({id: id}),
    success: function(message) {
      successToast(message);
      $.get('/wrapper-users-list', function(data) { $('#users').html(data); });
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function saveUser(id, name, role) {
  $.ajax({
    url: '/wrapper-users/save',
    type: 'POST',
    contentType: "application/json",
    data: JSON.stringify({id: id, name: name, role: role}),
    success: function(message) {
      successToast(message);
      $.get('/wrapper-users-list', function(data) { $('#users').html(data); });
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function updateWrapper() {
  successToast('Updating Sandstorm Admin Wrapper...');
  $.ajax({
    url: '/update-wrapper',
    type: 'POST',
    success: response => {
      successToast(response);
    },
    error: (request, msg, error) => {
      failureToast(request.responseText);
    }
  });
}

function restartWrapper() {
  $.ajax({
    url: '/restart-wrapper',
    type: 'POST',
    success: function() {
      successToast("Wrapper is restarting.");
      setTimeout(()=>{ window.location.href = '/wrapper-config'; }, 2000);
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function logIn(destination) {
  var user = $('#user_name_input').val();
  var pass = $('#user_password_input').val();
  $.ajax({
    url: '/login',
    type: 'POST',
    contentType: "application/json",
    data: JSON.stringify({user: user, pass: pass, destination: destination}),
    success: function(endpoint) {
      successToast("Logged in successfully!");
      setTimeout(function() { window.location.href = (endpoint || '/'); }, 600);
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function changePassword(destination) {
  var pass1 = $('#user_password_input').val();
  var pass2 = $('#user_password_second_input').val();
  if (pass1 !== pass2) {
    failureToast("Given passwords do not match.");
  } else {
    $.ajax({
      url: '/change-password',
      type: 'POST',
      contentType: "application/json",
      data: JSON.stringify({pass: pass1, destination: destination}),
      success: function(endpoint) {
        successToast("Password changed successfully!");
        setTimeout(function() { window.location.href = endpoint; }, 600);
      },
      error: function(request,msg,error) {
        failureToast(request.responseText);
      }
    });
  }
}

function updateServerUpdateInfo() {
  $.ajax({
    url: '/update-info',
    type: 'GET',
    success: function(data) {
      $('#server-update-info').html(data);
    },
    error: function(request,msg,error) {
      console.log("Failed to request server update info.");
    }
  });
}

function startServerLogTail(element, game_port, interval) {
  if (!server_log_active) {
    server_log_active = true;
     $.ajax({
      url: `/get-buffer/${game_port}/server`,
      type: 'GET',
      success: (buffer_uuid)=>{ server_log_uuid = buffer_uuid; setTimeout(()=>{ tailBuffer(element, interval, buffer_uuid) }, 0);},
      error: function(request,msg,error) {
        console.log(`Failed to start server log for port ${game_port}.`);
        server_log_active = false;
      }
    });
  } else {
    console.error("Server log tail already running");
  }
}

function startServerRconTail(element, game_port, interval) {
  if (!server_rcon_log_active) {
    server_rcon_log_active = true;
     $.ajax({
      url: `/get-buffer/${game_port}/rcon`,
      type: 'GET',
      success: (buffer_uuid)=>{ rcon_log_uuid = buffer_uuid; setTimeout(()=>{ tailBuffer(element, interval, buffer_uuid) }, 0);},
      error: function(request,msg,error) {
        console.log(`Failed to start rcon log for port ${game_port}.`);
        server_rcon_log_active = false;
      }
    });
  } else {
    console.error("Server RCON log tail already running");
  }
}

function updateServerList(element) {
  $.ajax({
    url: `/server-list`,
    type: 'GET',
    success: function(data) {
      $(element || '#server-list').html(data);
    },
    error: function(request,msg,error) {
      console.log("Failed to request server list.");
    }
  });
}

function updatePlayers(game_port, element) {
 $.ajax({
    url: `/players/${game_port}`,
    type: 'GET',
    success: function(data) {
      $(element || '#players').html(data);
    },
    error: function(request,msg,error) {
      console.log("Failed to request players.");
    }
  });
}

function updateThreads(game_port, element) {
 $.ajax({
    url: `/threads/${game_port}`,
    type: 'GET',
    success: function(data) {
      $(element || '#threads').html(data);
    },
    error: function(request,msg,error) {
      console.log("Failed to request threads.");
    }
  });
}

function reloadControlStatus() {
  $.ajax({
    url: `/server-control-status`,
    type: 'GET',
    success: (response) => {
      $('#server-control-status').html(response);
    },
    error: (request, msg, error) => {
      console.log("Failed to get server control status: " + request.responseText);
    }
  });
}

function updateServerControlStatus() {
  reloadControlStatus();
  game_port = $('#game-port').html();
  rcon_port = $('#rcon-port').html();
  if ($('#server-status').html() == 'ON') {
    if (!server_log_active && $('#server-log').length) {
      setTimeout(()=>{startServerLogTail('#server-log', game_port, server_log_tail_interval);}, 0);
    }
    if (!server_rcon_log_active && $('#rcon-log').length) {
      setTimeout(()=>{startServerRconTail('#rcon-log', game_port, server_log_tail_interval);}, 0);
    }
  }
  setTimeout(()=>{updateServerControlStatus();}, 1000);
}

function addLogLines(target, lines) {
  var target = $(target);
  var wasScrolled = target[0].clientHeight !== target[0].scrollHeight && target[0].scrollTop !== target[0].scrollHeight - target[0].clientHeight

  // Add log lines to a temporary non-visible element
  var temp = $("<div style='display: none'>");
  $("body").append(temp);
  $.each(lines, function(index, text) {
    addLogLine(temp, text);
  });

  // Trim the temp element before applying
  if(temp.contents().length > log_buffer_size) {
    temp.html(temp.contents().slice(temp.contents().length - log_buffer_size, temp.contents().length));
  }

  // Apply
  target.append(temp.html());
  temp.remove();
  // Trim the final element after applying
  if(target.contents().length > log_buffer_size) {
    target.html(target.contents().slice(target.contents().length - log_buffer_size, target.contents().length));
  }

  if (!wasScrolled) {
    resetLogScroll(target);
  }
}

function addLogLine(target, text, colorful) {
  text = _.escape(text)
  if (colorful !== false) {
    if (~text.indexOf('Error')) {
      text = `<span class="logspan" style="background-color: #FFE1E0;">${text}</span>\n`;
    } else if (~text.indexOf('Warning')) {
      text = `<span class="logspan" style="background-color: #F2EFCD;">${text}</span>\n`;
    } else {
      text = `<span class="logspan">${text}</span>\n`;
    }
  } else {
    text = `<span class="logspan">${text}</span>\n`;
  }
  target.append(
    text
  );
}

function resetLogScroll(target)
{
  // console.log("Resetting log pane for " + target);
  var el = $(target)
  el[0].scrollTop = el[0].scrollHeight;
}

function successToast(string) {
  if (typeof string === 'undefined') {
    string = '';
  }
  toast = $('#toast-template-success').clone().removeAttr('id');
  $('#toast-container').append(toast);
  console.log(`Success toasting: ${string}`);
  if (!string.trim()) {
    string = "Success";
  }
  toast.children().children().text(string)
  toast.toast('show')
  toast.get(0).scrollIntoView();
  toast.on('hidden.bs.toast', function () {
    $(this).remove();
  });
}

function failureToast(string) {
  if (typeof string === 'undefined') {
    string = '';
  }
  toast = $('#toast-template-failure').clone().removeAttr('id');
  $('#toast-container').append(toast);
  console.log(`Failure toasting: ${string}`);
  if (!string.trim()) {
    string = "Failure";
  }
  toast.children().children().text(string)
  toast.toast('show')
  toast.get(0).scrollIntoView();
  toast.on('hidden.bs.toast', function () {
    $(this).remove();
  });
}

function copyToClipboard(element, sensitive) {
  var $temp = $("<input>");
  $("body").append($temp);
  var text = $(element).text().trim() || $(element).val().trim() || $(element).attr('placeholder').trim()
  $temp.val(text).select();
  document.execCommand("copy");
  if (typeof sensitive === 'undefined' || !sensitive) {
    successToast(`Successfully copied '${$temp.val()}' to clipboard!`);
  } else {
    successToast(`Successfully copied text to clipboard!`);
  }
  $temp.remove();
}

function capitalize(string) {
  return string.charAt(0).toUpperCase() + string.slice(1);
}

function launchSandstorm() {
  successToast('Launching Insurgency: Sandstorm via Steam')
  window.location.replace('steam://run/581320')
}

function confirmModal(title, body, yes_func, no_func) {
  modal_content = $('#confirm_modal_content')
  $.get(`/confirm?title=${title}&body=${body}&yes=${yes_func}&no=${no_func}`, function(data) {
    modal_content.html(data);
  });
}

function revealHide(identifier, button) {
  $(identifier).toggleClass('blur');
  button_text = $(button).text();
  if (button_text == 'Reveal') {
    $(button).text('Hide');
  } else if (button_text == 'Hide') {
    $(button).text('Reveal');
  }
}

function toggleURLType(to_type) {
  if (to_type == "steam") {
    webToSteamURLs();
  } else {
    steamToWebURLs();
  }
}

function webToSteamURLs() {
  $("a").each( function(){ $(this).attr('href', $(this).attr('href').replace(/https:\/\/steamcommunity.com\/profiles/, 'steam://url/SteamIDPage')); $(this).attr('target', '');});
}

function steamToWebURLs() {
  $("a").each( function(){ $(this).attr('href', $(this).attr('href').replace(/steam:\/\/url\/SteamIDPage/, 'https://steamcommunity.com/profiles')); $(this).attr('target', '_blank');});
}

// Config

function toggleChecked(identifier) {
  var element = $(identifier);
  var checked = element[0].checked;
  element.prop('checked', !checked)
}

function undoServerConfig(config_name, variable) {
  var previous = $(`#${variable}`).attr('previous');
  if (previous) {
    setServerConfig(config_name, variable, previous);
  } else {
    failureToast("No previous value to reinstate.");
  }
}

function loadPreviousServerConfig() {
  var previous = $(`#server-config-name`).attr('previous');
  if (previous) {
    loadServerConfig(previous);
  } else {
    failureToast("No previous value to reinstate.");
  }
}

function loadServerConfigFileContent(config_name) {
  if ($('#config-files-tab-content').length) {
    setTimeout(()=>{getConfigFileContent(config_name, '#game-ini')}, 0);
    setTimeout(()=>{getConfigFileContent(config_name, '#engine-ini')}, 10);
    setTimeout(()=>{getConfigFileContent(config_name, '#admins-txt')}, 20);
    setTimeout(()=>{getConfigFileContent(config_name, '#mapcycle-txt')}, 30);
    setTimeout(()=>{getConfigFileContent(config_name, '#bans-json')}, 40);
  }
}

function setServerConfig(config_name, variable, value) {
  $.ajax({
      url: `/config/set?config=${encodeURIComponent(config_name)}&variable=${encodeURIComponent(variable)}&value=${encodeURIComponent(value)}`,
      type: 'PUT',
      success: function(response) {
        $(`#${variable}`).attr('previous', $(`#${variable}`).attr('placeholder'));
        if ($(`#${variable}`).is('[placeholder]')) { $(`#${variable}`).attr('placeholder', value); }
        $(`#${variable}`).val("");
        loadServerConfigFileContent(config_name);
        successToast(response);
      },
      error: function(request,msg,error) {
        failureToast(request.responseText);
      }
  });
}

function undoWrapperConfig(variable) {
  var previous = $(`#${variable}`).attr('previous');
  if (previous) {
    setWrapperConfig(variable, previous);
  } else {
    failureToast("No previous value to reinstate.");
  }
}

function setWrapperConfig(variable, value) {
  $.ajax({
      url: `/wrapper-config/set?variable=${encodeURIComponent(variable)}&value=${encodeURIComponent(value)}`,
      type: 'PUT',
      success: function(response) {
        $(`#${variable}`).attr('previous', $(`#${variable}`).attr('placeholder'));
        if ($(`#${variable}`).is('[placeholder]')) { $(`#${variable}`).attr('placeholder', value); }
        $(`#${variable}`).val("");
        successToast(response);
      },
      error: function(request,msg,error) {
        failureToast(request.responseText);
      }
  });
}

function getConfigFileContent(config_name, identifier) {
  var element = $(identifier);
  var file = element.attr('file');
  $.ajax({
      url: `/config/file/${encodeURIComponent(file)}?config=${encodeURIComponent(config_name)}`,
      type: 'GET',
      success: function(response) {
        element.val(response);
      },
      error: function(request,msg,error) {
        console.log("Failed to get config file content: " + request.responseText);
      }
  });
}

function serverControl(action, game_port, config_name) {
  $.ajax({
      url: `/control/server/${encodeURIComponent(action)}`,
      type: 'POST',
      data: JSON.stringify({config_name: config_name, game_port: game_port}),
      success: function(response) {
        successToast(response);
      },
      error: function(request,msg,error) {
        failureToast(request.responseText);
      }
  });
}

function writeConfigFiles(config_name) {
  setTimeout(
    ()=>{
      $('#config-files-tab-content').children().each((i, e)=>{
        var textarea = $(e).children().first().attr('id');
        writeConfigFile(config_name, textarea, true);
      });
    }
  ,0);
}

function writeConfigFile(config_name, textarea, suppress_toasts) {
  if (textarea) {
    var textarea = $(`#${textarea}`);
  } else {
    var textarea = $('#config-files-tab-content').children('.active').first().children('textarea').first();
  }
  var file = textarea.attr('file');
  var content = textarea.val();
  $.ajax({
    url: `/config/file/${file}?config=${config_name}`,
    type: 'POST',
    data: {'content': content},
    success: function(response) {
      if (!suppress_toasts) {
        successToast(response);
      }
    },
    error: function(request,msg,error) {
      if (!suppress_toasts) {
        failureToast(request.responseText);
      }
    }
  });
}

function tailProcess(logElement, url, interval, data) {
  if (!data) {
    data = "{}";
  }
  if (!interval) {
    interval = 1000;
  }
  $.ajax({
      url: url,
      type: 'POST',
      data: JSON.stringify(data),
      success: function(uuid) {
        tailBuffer(logElement, interval, uuid);
      },
      error: function(request,msg,error) {
        failureToast(request.responseText);
      }
  });
}

function tailBuffer(logElement, interval, uuid, bookmark) {
  if (tailBufferStopUuids.length > 0 && tailBufferStopUuids.includes(uuid)) {
    tailBufferStopUuids.splice(tailBufferStopUuids.indexOf(uuid), 1);
    console.log("Stopping buffer for UUID " + uuid);
    return;
  }
  if (!interval) {
    interval = 1000;
  }
  var url = `/buffer/${uuid}`;
  if (bookmark) {
    url = `${url}/${bookmark}`;
  }
  // console.log("Getting URL: " + url);
  $.ajax({
    url: url,
    type: 'GET',
    success: function(data) {
      var response = $.parseJSON(data);
      // console.log("Got response for URL: " + url);
      // console.log("Data: " + JSON.stringify(response));
      if (typeof response.status !== 'undefined') {
        // Command is finished (status and message received)

        // Indicate that we're stopping tailing of server log if buffer uuid matches
        if (uuid == server_log_uuid) {
          server_log_active = false;
        } else if (uuid == rcon_log_uuid) {
          server_rcon_log_active = false;
        }

        if (response.status) {
          successToast(response.message);
        } else {
          failureToast(response.message);
        }
      } else {
        if (uuid == server_log_uuid) {
          server_log_active = true;
        } else if (uuid == rcon_log_uuid) {
          server_rcon_log_active = true;
        }
        // console.log(`Adding ${response.data.length} log lines`)
        if(response.data.length > 0) {
          addLogLines(logElement, response.data);
        }
        // console.log(`Finished adding ${response.data.length} log lines`)
        // console.log("Bookmark: " + response.bookmark)
        setTimeout(function() { tailBuffer(logElement, interval, uuid, response.bookmark); }, interval);
      }
    },
    error: function(request,msg,error) {
      if (uuid == server_log_uuid) {
        server_log_active = false;
      } else if (uuid == rcon_log_uuid) {
        server_rcon_log_active = false;
      }
      console.log(request.responseText);
    }
  });
}

function playerBan(ip, port, pass, steam_id, reason, log_element) {
  if (typeof log_element === 'undefined') {
    log_element = '#rcon-log'
  }
  $.ajax({
    url: `/admin/ban/${steam_id}`,
    data: JSON.stringify({reason: reason, ip: ip, port: port, pass: pass}),
    type: 'POST',
    success: function(response) {
      successToast(`Banning ${steam_id}`);
      tailBuffer(log_element, 200, response);
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function playerKick(ip, port, pass, steam_id, reason, log_element) {
  if (typeof log_element === 'undefined') {
    log_element = '#rcon-log'
  }
  $.ajax({
    url: `/admin/kick/${steam_id}`,
    data: JSON.stringify({reason: reason, ip: ip, port: port, pass: pass}),
    type: 'POST',
    success: function(response) {
      successToast(`Kicking ${steam_id}`);
      tailBuffer(log_element, 200, response);
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function disableAutomaticUpdates() {
  $.ajax({
    url: '/automatic-updates/disable',
    type: 'POST',
    success: function(response) {
      successToast(response);
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function enableAutomaticUpdates() {
  $.ajax({
    url: '/automatic-updates/enable',
    type: 'POST',
    success: function(response) {
      successToast(response);
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
    }
  });
}

function setMutatorCount() {
  var size = $('.server-config-mutator-input').filter(":checked").length;
  $('#mutator-count').html(size);
}

function generatePassword(element) {
  $.get('/generate-password', (password) => { $(element).val(password); });
}

function download(url) {
  var link = document.createElement("a");
  link.download = name;
  link.href = url;
  link.style.display = "none";

  document.body.appendChild(link);
  if (typeof MouseEvent !== "undefined") {
      link.dispatchEvent(new MouseEvent("click"));
  } else {
      link.click();
  }
  document.body.removeChild(link);
}
