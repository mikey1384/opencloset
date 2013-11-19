// Generated by CoffeeScript 1.6.3
(function() {
  $(function() {
    var add_registered_donor, clear_cloth_form, donorID, userID, validation;
    userID = void 0;
    donorID = '';
    add_registered_donor = function() {
      var query;
      query = $('#donor-search').val();
      if (!query) {
        return;
      }
      return $.ajax("/new-cloth.json", {
        type: 'GET',
        data: {
          q: query
        },
        success: function(donors, textStatus, jqXHR) {
          var compiled;
          compiled = _.template($('#tpl-new-cloth-donor-id').html());
          return _.each(donors, function(donor) {
            var $html;
            if (!$("#donor-search-list input[data-donor-id='" + donor.id + "']").length) {
              $html = $(compiled(donor));
              $html.find('input').attr('data-json', JSON.stringify(donor));
              return $("#donor-search-list").prepend($html);
            }
          });
        },
        error: function(jqXHR, textStatus, errorThrown) {
          return alert('error', jqXHR.responseJSON.error);
        },
        complete: function(jqXHR, textStatus) {}
      });
    };
    $('#donor-search').keypress(function(e) {
      if (e.keyCode === 13) {
        return add_registered_donor();
      }
    });
    $('#btn-donor-search').click(function() {
      return add_registered_donor();
    });
    $('#donor-search-list').on('click', ':radio', function(e) {
      var g;
      userID = $(this).data('user-id');
      donorID = $(this).data('donor-id');
      if ($(this).val() === '0') {
        return;
      }
      g = JSON.parse($(this).attr('data-json'));
      return _.each(['name', 'email', 'gender', 'phone', 'age', 'address', 'donation_msg', 'comment'], function(name) {
        var $input;
        $input = $("input[name=" + name + "]");
        if ($input.attr('type') === 'radio' || $input.attr('type') === 'checkbox') {
          return $input.each(function(i, el) {
            if ($(el).val() === g[name]) {
              return $(el).attr('checked', true);
            }
          });
        } else {
          return $input.val(g[name]);
        }
      });
    });
    clear_cloth_form = function(show) {
      if (show) {
        _.each(['bust', 'waist', 'hip', 'arm', 'length', 'foot'], function(name) {
          return $("#display-cloth-" + name).show();
        });
      } else {
        _.each(['bust', 'waist', 'hip', 'arm', 'length', 'foot'], function(name) {
          return $("#display-cloth-" + name).hide();
        });
      }
      $('input[name=cloth-gender]').prop('checked', false);
      $('#cloth-color').select2('val', '');
      return _.each(['bust', 'waist', 'hip', 'arm', 'length', 'foot'], function(name) {
        return $("#cloth-" + name).prop('disabled', true).val('');
      });
    };
    $('#cloth-type').select2({
      dropdownCssClass: 'bigdrop'
    }).on('change', function(e) {
      var type, types, _i, _len, _results;
      clear_cloth_form(false);
      types = [];
      switch (parseInt(e.val, 10)) {
        case 0x0001 | 0x0002:
          types = ['bust', 'arm', 'waist', 'length'];
          break;
        case 0x0001 | 0x0020:
          types = ['bust', 'arm', 'waist', 'hip', 'length'];
          break;
        case 0x0001:
        case 0x0004:
        case 0x0080:
        case 0x0400:
          types = ['bust', 'arm'];
          break;
        case 0x0002:
          types = ['waist', 'length'];
          break;
        case 0x0200:
          types = ['waist', 'hip', 'length'];
          break;
        case 0x0008:
          types = ['foot'];
          break;
        case 0x0040:
          types = ['waist'];
          break;
        case 0x0010:
        case 0x0020:
        case 0x0100:
          types = [];
          break;
        default:
          types = [];
      }
      _results = [];
      for (_i = 0, _len = types.length; _i < _len; _i++) {
        type = types[_i];
        $("#display-cloth-" + type).show();
        _results.push($("#cloth-" + type).prop('disabled', false));
      }
      return _results;
    });
    $('#cloth-color').select2();
    $('#cloth-type').select2('val', '');
    clear_cloth_form(true);
    $('#btn-cloth-reset').click(function() {
      $('#cloth-type').select2('val', '');
      return clear_cloth_form(true);
    });
    $('#btn-cloth-add').click(function() {
      var compiled, count, data, html, valid_count;
      data = {
        donor_id: donorID,
        cloth_type: $('#cloth-type').val(),
        cloth_type_str: $('#cloth-type option:selected').text(),
        cloth_gender: $('input[name=cloth-gender]:checked').val(),
        cloth_gender_str: $('input[name=cloth-gender]:checked').next().text(),
        cloth_color: $('#cloth-color').val(),
        cloth_color_str: $('#cloth-color option:selected').text(),
        cloth_bust: $('#cloth-bust').val(),
        cloth_waist: $('#cloth-waist').val(),
        cloth_hip: $('#cloth-hip').val(),
        cloth_arm: $('#cloth-arm').val(),
        cloth_length: $('#cloth-length').val(),
        cloth_foot: $('#cloth-foot').val()
      };
      if (!data.cloth_type) {
        return;
      }
      count = 0;
      valid_count = 0;
      if ($('#cloth-color').val()) {
        count++;
        valid_count++;
      } else {
        count++;
      }
      $('#step3 input:enabled').each(function(i, el) {
        if (!/^cloth-/.test($(el).attr('id'))) {
          return;
        }
        count++;
        if ($(el).val() > 0) {
          return valid_count++;
        }
      });
      if (count !== valid_count) {
        return;
      }
      compiled = _.template($('#tpl-new-cloth-cloth-item').html());
      html = $(compiled(data));
      $('#display-cloth-list').append(html);
      $('#btn-cloth-reset').click();
      return $('#cloth-type').focus();
    });
    validation = false;
    return $('#fuelux-wizard').ace_wizard().on('change', function(e, info) {
      var ajax;
      if (info.step === 1 && validation) {
        if (!$('#validation-form').valid()) {
          return false;
        }
      }
      ajax = {};
      switch (info.step) {
        case 2:
          if (!$('#donor-name').val()) {
            return;
          }
          ajax.type = 'POST';
          ajax.path = '/users.json';
          if (userID) {
            ajax.type = 'PUT';
            ajax.path = "/users/" + userID + ".json";
          }
          return $.ajax(ajax.path, {
            type: ajax.type,
            data: $('form').serialize(),
            success: function(data, textStatus, jqXHR) {
              userID = data.id;
              if (donorID) {
                ajax.type = 'PUT';
                ajax.path = "/donors/" + donorID + ".json";
              } else {
                ajax.type = 'POST';
                ajax.path = "/donors.json?user_id=" + userID;
              }
              return $.ajax(ajax.path, {
                type: ajax.type,
                data: $('form').serialize(),
                success: function(data, textStatus, jqXHR) {
                  donorID = data.id;
                  return true;
                },
                error: function(jqXHR, textStatus, errorThrown) {
                  alert('error', jqXHR.responseJSON.error);
                  return false;
                },
                complete: function(jqXHR, textStatus) {}
              });
            },
            error: function(jqXHR, textStatus, errorThrown) {
              alert('error', jqXHR.responseJSON.error);
              return false;
            },
            complete: function(jqXHR, textStatus) {}
          });
        case 3:
          if (!$("input[name=cloth-list]:checked").length) {
            return;
          }
          return $.ajax('/clothes.json', {
            type: 'POST',
            data: $('form').serialize(),
            success: function(data, textStatus, jqXHR) {
              return true;
            },
            error: function(jqXHR, textStatus, errorThrown) {
              alert('error', jqXHR.responseJSON.error);
              return false;
            },
            complete: function(jqXHR, textStatus) {}
          });
      }
    }).on('finished', function(e) {
      location.href = "/";
      return false;
    }).on('stepclick', function(e) {});
  });

}).call(this);
