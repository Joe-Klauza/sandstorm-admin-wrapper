var touchDevice = (navigator.maxTouchPoints || 'ontouchstart' in document.documentElement);
if (touchDevice) {
  var tooltipTrigger = 'hover click'
} else {
  var tooltipTrigger = 'hover'
}

var server_log_active = false;
var server_rcon_log_active = false;
var server_chat_log_active = false;

var server_log_uuid = null;
var rcon_log_uuid = null;
var chat_log_uuid = null;

var log_buffer_size = 500;
var server_log_tail_interval = 2000;
var server_status_interval = 2000;

var updatePlayersInterval = null;
var updateThreadsInterval = null;
var updateMonitoringDetailsInterval = null;

var tailBufferUuids = [];
var tailBufferStopUuids = [];

(function ($) {
  var originalVal = $.fn.val;
  $.fn.val = function(value) {
    let returnedElement = originalVal.apply(this, arguments);
    if (arguments.length >= 1) {
      // setter invoked
      returnedElement.trigger('change');
    }
    return returnedElement;
  };
})(jQuery);

$(document).ready(function() {
  $(() => {
    $('[data-toggle="tooltip"]').tooltip({ trigger : tooltipTrigger, container : 'body' })
  });

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

  $(function() {
    $("#sortable").sortable({
      handle: ".drag-handle",
      distance: 10,
      update: (event, ui)=>{  }
    });
    $("#sortable").disableSelection();
  });

  // Keep logs selectable for copy/paste
  $("pre, .logspan").bind('mousedown.ui-disableSelection selectstart.ui-disableSelection', function(e){
    e.stopImmediatePropagation();
  });

  if ($('#chat-log').length) $('#chat-log').css("resize", "vertical");
  if ($('#server-log').length) $('#server-log').css("resize", "vertical");
  if ($('#rcon-log').length) $('#rcon-log').css("resize", "vertical");

  // Server config changes
  var observer = new MutationObserver(function(mutations) {
    mutations.forEach(function(event) {
      if (event.type === 'attributes' && event.attributeName === 'placeholder') {
        setConfigChangeBorderColor(event);
      }
    });
  });

  $(".server-config-text-input").each((i, element) => {
    observer.observe(element, {
      attributes: true
    });
  });

  // Server config change indicators
  $(".server-config-text-input").on({
    'input': $.debounce(100, setConfigChangeBorderColor),
    'change': $.debounce(100, setConfigChangeBorderColor)
  }, $(".server-config-text-input"));

  $("#server_lighting_day").change(function () {
      $('#server_lighting_day_label').text($('#server_lighting_day').is(':checked') ? 'Day' : 'Night');
  });
});

function setConfigChangeBorderColor(event) {
  let e = event.target;
  let $e = $(e);
  let placeholder = $e.attr('placeholder');
  let val = $e.val();
  if (val.length === 0 || placeholder === val) {
    e.classList.remove('config-changed');
  } else {
    e.classList.add('config-changed');
  }
}

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
  $.get(`/monitor-config/${encodeURIComponent(name)}`, function(data) {
    data = JSON.parse(data);
    $('#monitor-config-id').html(data['id']);
    $('#name').val(''); $('#name').attr('placeholder', data['name']);
    $('#ip').val(''); $('#ip').attr('placeholder', data['ip']);
    $('#query_port').val(''); $('#query_port').attr('placeholder', data['query_port']);
    $('#rcon_port').val(''); $('#rcon_port').attr('placeholder', data['rcon_port']);
    $('#rcon_password').val(''); $('#rcon_password').attr('placeholder', data['rcon_password']);
    clearInterval(updateMonitoringDetailsInterval);
    $('#monitoring-details').html('');
    if (data.running) {
      startMonitoringDetailsInterval(data['id']);
    } else {
      monitorButtonStart();
    }
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

function startMonitoringDetailsInterval(id, element) {
  clearInterval(updateMonitoringDetailsInterval);
  setTimeout(() => { updateMonitoringDetails(id, element); }, 750);
  updateMonitoringDetailsInterval = setInterval(() => { updateMonitoringDetails(id, element); }, 2000);
  startRemoteRconTail(id);
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

function toggleMonitor(id) {
  id = id || $('#monitor-config-id').html()
  if ($('#start-stop-monitor').html() === 'Start Monitor') {
    startMonitor(id);
  } else {
    stopMonitor(id);
  }
}

function updateMonitoringDetails(id, element) {
  if (typeof element === 'undefined') {
    element = '#monitoring-details'
  }
  $.get(`/monitoring-details/${id}`, function(data){ $(element).html(data); });
}

function startRemoteRconTail(id) {
  tailBufferStopUuids = tailBufferUuids
  tailBufferUuids = []
  $.get(`/monitor/${id}`, (rcon_buffer_uuid)=>{ tailBufferUuids.push(rcon_buffer_uuid); tailBuffer('#rcon-log', 1000, rcon_buffer_uuid); });
}

function startMonitor(id) {
  $.ajax({
    url: `/monitor/${id}/start`,
    type: 'POST',
    contentType: "application/json",
    success: function(message) {
      successToast(message);
      monitorButtonStop();
      startMonitoringDetailsInterval(id);
      loadActiveMonitors();
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
      monitorButtonStop();
      startMonitoringDetailsInterval(id);
      loadActiveMonitors();
    }
  });
}

function stopMonitor(id) {
  $.ajax({
    url: `/monitor/${id}/stop`,
    type: 'POST',
    contentType: "application/json",
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
    success: function(data) {
      data = JSON.parse(data);
      if (data['id'] !== $('#monitor-config-id').html()) {
        // New monitor saved; make sure button allows start
        monitorButtonStart();
        $('#monitoring-details').html('');
      }
      $('#monitor-config-id').html(data['id']);
      $('#name').val(''); $('#name').attr('placeholder', data['name']);
      $('#ip').val(''); $('#ip').attr('placeholder', data['ip']);
      $('#query_port').val(''); $('#query_port').attr('placeholder', data['query_port']);
      $('#rcon_port').val(''); $('#rcon_port').attr('placeholder', data['rcon_port']);
      $('#rcon_password').val(''); $('#rcon_password').attr('placeholder', data['rcon_password']);
      successToast(data['message']);
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

function loadActiveServerConfig(config_id) {
  $.get(`/daemon/${config_id}`, (data) => {
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
      // console.log(`${key} => ${val} (${typeof val})`);
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
          if (element[0].checked.toString() !== val.toString()) { // Handle boolean and string
            element[0].click();
          }
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
  name = filterConfigName(name);
  writeConfigFiles(name);
  $.ajax({
    url: `/server-config`,
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
      setTimeout(()=>{ location.reload(true); }, 3000);
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

function startServerChatTail(element, config_id, interval) {
  if (!server_chat_log_active) {
    server_chat_log_active = true;
    $.ajax({
      url: `/get-buffer/${config_id}/chat`,
      type: 'GET',
      success: (buffer_uuid)=>{ chat_log_uuid = buffer_uuid; setTimeout(()=>{ tailBuffer(element, interval, buffer_uuid) }, 0);},
      error: function(request,msg,error) {
        console.log(`Failed to start chat log for config ID ${config_id}.`);
        server_chat_log_active = false;
      }
    });
  } else {
    console.error("Server chat log tail already running");
  }
}

function startServerLogTail(element, config_id, interval) {
  if (!server_log_active) {
    server_log_active = true;
    $.ajax({
      url: `/get-buffer/${config_id}/server`,
      type: 'GET',
      success: (buffer_uuid)=>{ server_log_uuid = buffer_uuid; setTimeout(()=>{ tailBuffer(element, interval, buffer_uuid) }, 0);},
      error: function(request,msg,error) {
        console.log(`Failed to start server log for config ID ${config_id}.`);
        server_log_active = false;
      }
    });
  } else {
    console.error("Server log tail already running");
  }
}

function startServerRconTail(element, config_id, interval) {
  if (!server_rcon_log_active) {
    server_rcon_log_active = true;
    $.ajax({
      url: `/get-buffer/${config_id}/rcon`,
      type: 'GET',
      success: (buffer_uuid)=>{ rcon_log_uuid = buffer_uuid; setTimeout(()=>{ tailBuffer(element, interval, buffer_uuid) }, 0);},
      error: function(request,msg,error) {
        console.log(`Failed to start rcon log for config ID ${config_id}.`);
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

function updatePlayers(id, element) {
 $.ajax({
    url: `/players/${id}`,
    type: 'GET',
    success: function(data) {
      $(element || '#players').html(data);
    },
    error: function(request,msg,error) {
      console.log("Failed to request players.");
    }
  });
}

function updateThreads(id, element) {
 $.ajax({
    url: `/threads/${id}`,
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
  id = $('#config-id').html();
  if (id && $('#server-status').html() == 'ON') {
    if (!server_chat_log_active && $('#chat-log').length) {
      setTimeout(()=>{startServerChatTail('#chat-log', id, server_log_tail_interval);}, 0);
    }
    if (!server_log_active && $('#server-log').length) {
      setTimeout(()=>{startServerLogTail('#server-log', id, server_log_tail_interval);}, 0);
    }
    if (!server_rcon_log_active && $('#rcon-log').length) {
      setTimeout(()=>{startServerRconTail('#rcon-log', id, server_log_tail_interval);}, 0);
    }
  }
  setTimeout(()=>{updateServerControlStatus();}, 1000);
  setTimeout(()=>{updateMonitoringDetails(id);}, 1000);
}

function addLogLines(target, lines) {
  var target = $(target);
  var wasScrolled = target[0].clientHeight <= target[0].scrollHeight && Math.floor(target[0].scrollTop) !== target[0].scrollHeight - target[0].clientHeight

  // Remove excess log messages first
  if(target.contents().length + lines.length > log_buffer_size) {
    amount = lines.length
    // console.log(`Removing ${amount} oldest elements from ${target[0].id}`)
    target.contents().slice(0, amount).remove() // Once to remove the span
    target.contents().slice(0, amount).remove() // Again to remove the leftover text creating whitespace...
  }

  // console.log(`Adding ${lines.length} elements to ${target[0].id}`)
  $.each(lines, function(index, text) {
    addLogLine(target, text);
  });

  if (!wasScrolled) {
    resetLogScroll(target);
  }
}

function addLogLine(target, text, colorful) {
  text = _.escape(text)
  if (colorful !== false) {
    if (~text.indexOf('Error')) {
      text = `<span class="logspan" style="background-color: #553333 !important;">${text}</span>\n`;
    } else if (~text.indexOf('Warning')) {
      text = `<span class="logspan" style="background-color: #55523b !important;">${text}</span>\n`;
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

function fillFromPlaceholder(element) {
  let $element = $(element)
  $element.val($element.attr('placeholder'));
  $element.focus();
}

function capitalize(string) {
  return string.charAt(0).toUpperCase() + string.slice(1);
}

function launchSandstorm() {
  successToast('Launching Insurgency: Sandstorm via Steam')
  window.location.replace('steam://run/581320')
}

function confirmModal(title, body, yes_func, no_func, input_label) {
  modal_content = $('#confirm_modal_content')
  $.get(`/confirm?title=${encodeURIComponent(title)}&body=${encodeURIComponent(body)}&yes=${encodeURIComponent(yes_func)}&no=${encodeURIComponent(no_func)}&input_label=${encodeURIComponent(input_label)}`, function(data) {
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
  config_name = filterConfigName(config_name);
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
    previous = filterConfigName(previous);
    loadServerConfig(previous);
  } else {
    failureToast("No previous value to reinstate.");
  }
}

function loadServerConfigFileContent(config_name) {
  if ($('#config-files-tab-content').length) {
    let timeout = 0;
    $('#config-files-tab-content').children().each((i, e)=>{
      var textareaId = $(e).children().first().attr('id');
      setTimeout(()=>{getConfigFileContent(config_name, `#${textareaId}`);}, timeout);
      timeout += 10;
    });
  }
}

function filterConfigName(config_name) {
  let new_name = config_name.replace(/[^\w\s.&-]+/g, '');
  if (new_name !== config_name) $('#server-config-name').val(new_name);
  return new_name;
}

function setServerConfig(config_name, variable, value) {
  config_name = filterConfigName(config_name);
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

function serverControl(action, config_id) {
  $.ajax({
      url: `/control/server/${encodeURIComponent(action)}/${encodeURIComponent(config_id)}`,
      type: 'POST',
      success: function(response) {
        successToast(response);
      },
      error: function(request,msg,error) {
        failureToast(request.responseText);
      }
  });
}

function writeConfigFiles(config_name) {
  $('#config-files-tab-content').children().each((i, e)=>{
    var textareaId = $(e).children().first().attr('id');
    setTimeout(()=>{
      writeConfigFile(config_name, textareaId, true);
    }, 0);
  });

}

function writeConfigFile(config_name, textareaId, suppress_toasts) {
  let textarea = textareaId ? $(`#${textareaId}`) : $('#config-files-tab-content').children('.active').first().children('textarea').first();
  textareaId = textareaId || textarea.attr('id')
  let file = textarea.attr('file');
  let content = textarea.val();
  $.ajax({
    url: `/config/file/${file}?config=${config_name}`,
    type: 'POST',
    data: {'content': content},
    success: function(response) {
      if (textareaId === "mod-scenarios-txt") reloadMapList();
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

function reloadMapList() {
  $.get('/maplist', (mapListHtml) => {
    $('#maplist').html(mapListHtml);
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
    console.log(`${uuid} Stopping buffer`);
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
        console.log(`${logElement} ${url} Command finished for ${logElement}`)
        if (uuid == server_log_uuid) {
          server_log_active = false;
        } else if (uuid == rcon_log_uuid) {
          server_rcon_log_active = false;
        } else if (uuid == chat_log_uuid) {
          server_chat_log_active = false;
        }

        if (response.status) {
          successToast(response.message || '');
        } else {
          failureToast(response.message || '');
        }
      } else {
        if (uuid == server_log_uuid) {
          if (!server_log_active) { return }
        } else if (uuid == rcon_log_uuid) {
          if (!server_rcon_log_active) { return }
        } else if (uuid == chat_log_uuid) {
          if (!server_chat_log_active) { return }
        }

        if(logElement && response.data.length > 0) {
          addLogLines(logElement, response.data);
          console.log(`${logElement} ${url} Finished adding ${response.data.length} log lines to ${logElement}`)
        }

        if (!response.bookmark) {
          console.log(`${logElement} ${url} Bookmark is null! Response: ${JSON.stringify(response)}`)
        } else {
          console.log(`${logElement} ${url} Bookmark: ${response.bookmark}`)
        }
        setTimeout(function() { tailBuffer(logElement, interval, uuid, response.bookmark); }, interval);
      }
    },
    error: function(request,msg,error) {
      if (uuid == server_log_uuid) {
        server_log_active = false;
      } else if (uuid == rcon_log_uuid) {
        server_rcon_log_active = false;
      } else if (uuid == chat_log_uuid) {
        server_chat_log_active = false;
      }
      console.log(request.responseText);
    }
  });
}

function playerBan(id, steam_id, reason, log_element) {
  if (typeof log_element === 'undefined') {
    log_element = '#rcon-log'
  }
  $.ajax({
    url: `/moderator/ban/${steam_id}`,
    contentType: "application/json",
    data: JSON.stringify({reason: reason, id: id}),
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

function playerKick(id, steam_id, reason, log_element) {
  if (typeof log_element === 'undefined') {
    log_element = '#rcon-log'
  }
  $.ajax({
    url: `/moderator/kick/${steam_id}`,
    contentType: "application/json",
    data: JSON.stringify({reason: reason, id: id}),
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
