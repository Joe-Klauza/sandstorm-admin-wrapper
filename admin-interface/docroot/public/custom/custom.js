// var touchDevice = (navigator.maxTouchPoints || 'ontouchstart' in document.documentElement);
// if (touchDevice) {
//   var tooltipTrigger = 'hover click'
// } else {
//   var tooltipTrigger = 'hover'
// }

// var user_scrolled_tailing_log = false;
var server_log_active = false;
var server_rcon_log_active = false;

var log_buffer_size = 500;
var server_log_tail_interval = 250;

var updatePlayersInterval = null;
var updateThreadsInterval = null;


$(document).ready(function() {
//   $("body").tooltip({ selector: '[data-toggle=tooltip]', trigger : tooltipTrigger });

  // TO DO - abstract to all log elements; use element attribute to track scrolled state
  // if ($('#tailing-log').length) {
  //   target = $('#tailing-log');
  //   target[0].scrollTop = target[0].scrollHeight;
  //   $('#tailing-log').animate({ scrollTop: "300px" });
  //   $('#tailing-log').bind('mousedown wheel DOMMouseScroll mousewheel keyup', function(e){
  //       window.user_scrolled_tailing_log = true;
  //   });
  // }

  if ($('#server-status').length) {
    setInterval(updateServerStatusBadge, 500);
  }

  if ($('#server-update-info').length) {
    setTimeout(updateServerUpdateInfo, 1);
    setInterval(updateServerUpdateInfo, 30000);
  }

  // if ($('#server-log-container').length) {
  //   $( "#server-log-container" ).resizable({ handles: "n, e, s, w, se, sw, nw, ne" });
  // }
});

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
      setTimeout(function() { window.location.href = endpoint; }, 600);
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

function startServerLogTail(element, interval) {
  if (!server_log_active) {
    server_log_active = true;
    setTimeout(tailBuffer(element, interval, '0'), 0);
  } else {
    console.error("Server log tail already running");
  }
}

function startServerRconTail(element, interval) {
  if (!server_rcon_log_active) {
    server_rcon_log_active = true;
    setTimeout(tailBuffer(element, interval, '1'), 0);
  } else {
    console.error("Server RCON log tail already running");
  }
}

function updatePlayers() {
 $.ajax({
    url: '/players',
    type: 'GET',
    success: function(data) {
      $('#players').replaceWith(data);
    },
    error: function(request,msg,error) {
      console.log("Failed to request players.");
    }
  });
}

function updateThreads() {
 $.ajax({
    url: '/threads',
    type: 'GET',
    success: function(data) {
      $('#threads').html(data);
    },
    error: function(request,msg,error) {
      console.log("Failed to request players.");
    }
  });
}

function updateServerStatusBadge() {
  $.get(`/script/server-status`, function(data) {
    if (data == 'OFF') {
      add = 'badge-danger'
      remove = 'badge-success'
      if (server_log_active) {
        server_log_active = false;
      }
      if (server_rcon_log_active) {
        server_rcon_log_active = false;
      }
      clearInterval(updatePlayersInterval);
      clearInterval(updateThreadsInterval);
      $('#threads').html('');
      setTimeout(updatePlayers, 50);
    } else {
      add = 'badge-success'
      remove = 'badge-danger'
      if (!server_log_active) {
        setTimeout(startServerLogTail('#server-log', server_log_tail_interval), 0);
        setTimeout(updatePlayers, 0);
        setTimeout(updateThreads, 0);
        updatePlayersInterval = setInterval(updatePlayers, 5000);
        updateThreadsInterval = setInterval(updateThreads, 5000)
      }
      if (!server_rcon_log_active) {
        setTimeout(startServerRconTail('#rcon-log', server_log_tail_interval), 0);
      }
    }
    $('#server-status').addClass(add).removeClass(remove).text(data);
  });
}

function addLogLines(target, lines) {
  $.each(lines, function(index, text) {
    addLogLine(target, text);
  });
  resetLogScroll(target);
}

function addLogLine(target, text, reset) {
  var el = $(target)
  text = _.escape(text)
  if (el.hasClass('colorful')) {
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
  el.append(
    text
  );
  if(el.contents().length > log_buffer_size) {
    el.html(el.contents().slice(el.contents().length - log_buffer_size, el.contents().length));
  }
  if (typeof reset !== 'undefined' && reset !== false) {
    resetLogScroll(target);
  }
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

function copyToClipboard(element) {
  var $temp = $("<input>");
  $("body").append($temp);
  $temp.val($(element).text().trim()).select();
  document.execCommand("copy");
  successToast(`Successfully copied '${$temp.val()}' to clipboard!`);
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

function undoServerConfig(variable) {
  var previous = $(`#${variable}_input`).attr('previous');
  if (previous) {
    setServerConfig(variable, previous);
  } else {
    failureToast("No previous value to reinstate.");
  }
}

function setServerConfig(variable, value) {
  $.ajax({
      url: `/config/set?variable=${encodeURIComponent(variable)}&value=${encodeURIComponent(value)}`,
      type: 'PUT',
      success: function(response) {
        $(`#${variable}_input`).attr('previous', $(`#${variable}_input`).attr('placeholder'));
        if ($(`#${variable}_input`).is('[placeholder]')) { $(`#${variable}_input`).attr('placeholder', value); }
        $(`#${variable}_input`).val("");
        if ($('#config-files-tab-content').length) {
          setTimeout(getConfigFileContent('#game-ini'), 0);
          setTimeout(getConfigFileContent('#engine-ini'), 0);
        }
        successToast(response);
      },
      error: function(request,msg,error) {
        failureToast(request.responseText);
      }
  });
}

function getConfigFileContent(identifier) {
  var element = $(identifier);
  var file = element.attr('file');
  $.ajax({
      url: `/config/file/${file}`,
      type: 'GET',
      success: function(response) {
        element.val(response);
      },
      error: function(request,msg,error) {
        console.log("Failed to get config file content: " + request.responseText);
      }
  });
}

function serverControl(action) {
  $.ajax({
      url: `/control/server/${action}`,
      type: 'POST',
      success: function(response) {
        successToast(response);
      },
      error: function(request,msg,error) {
        failureToast(request.responseText);
      }
  });
}

function writeConfigFile() {
  var textarea = $('#config-files-tab-content').children('.active').first().children('textarea').first();
  var file = textarea.attr('file');
  var content = textarea.val();
  $.ajax({
    url: `/config/file/${file}`,
    type: 'POST',
    data: {'content': content},
    success: function(response) {
      successToast(response);
    },
    error: function(request,msg,error) {
      failureToast(request.responseText);
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
      console.log("Got response for URL: " + url);
      // console.log("Data: " + JSON.stringify(response));
      if (typeof response.status !== 'undefined') {
        // Command is finished (status and message received)

        // Indicate that we're stopping tailing of server log if buffer uuid matches
        if (uuid == '0') {
          server_log_active = false;
        } else if (uuid == '1') {
          server_rcon_log_active = false;
        }

        if (response.status) {
          successToast(response.message);
        } else {
          failureToast(response.message);
        }
      } else {
        if (uuid == '0') {
          server_log_active = true;
        } else if (uuid == '1') {
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
      if (uuid == '0') {
        server_log_active = false;
      } else if (uuid == '1') {
        server_rcon_log_active = false;
      }
      console.log(request.responseText);
    }
  });
}
