$ ->
  $('.order-status').each (i, el) ->
    $(el).addClass OpenCloset.status[ $(el).data('status') ].css
    $(el).find('.order-status-str').html('연체중') if $(el).data('status') is '대여중' and $(el).data('late-fee') > 0

  #
  # inline editable field
  #
  $('.editable').each (i, el) ->
    params =
      mode:        'inline'
      showbuttons: 'true'
      emptytext:   '비어있음'
      pk:          $('#profile-user-info-data').data('pk')
      url: (params) ->
        url = $('#profile-user-info-data').data('url')
        data = {}
        data[params.name] = params.value
        $.ajax url,
          type: 'PUT'
          data: data

    switch $(el).attr('id')
      when 'user-name'
        params.type    = 'text'
        params.success = (response, newValue) ->
          $('.user-name').each (i, el) ->
            $(el).html newValue
      when 'user-gender'
        params.type   = 'select'
        params.source = [
          { value: 'male',   text: '남자' },
          { value: 'female', text: '여자' },
        ]
        params.display = (value) ->
          switch value
            when 'male'   then value_str = '남자'
            when 'female' then value_str = '여자'
            else               value_str = ''
          $(this).html value_str
      when 'user-staff'
        params.type   = 'select'
        params.source = [
          { value: '0', text: '고객' },
          { value: '1', text: '직원' },
        ]
        params.display = (value) ->
          if typeof value == 'number'
            value = value.toString()
          switch value
            when '0' then value_str = '고객'
            when '1' then value_str = '직원'
            else          value_str = ''
          $(this).html value_str
      when 'user-password'
        params.type      = 'password'
        params.emptytext = '비밀번호를 입력해주세요.'
        params.success   = (response, newValue) ->
          OpenCloset.alert 'info', '비밀번호 변경을 완료했습니다.'
      when 'user-comment'
        params.type = 'textarea'
      when 'user-wearon_date'
        params.type     = 'combodate'
        params.format   = 'YYYY-MM-DD'
        params.template = 'YYYY / MM / DD'
      when 'user-purpose2'
        params.type = 'textarea'
      when 'user-pre_category'
        params.type    = 'select2'
        params.source  = ( { id: i, text: OpenCloset.category[i].str } for i in [ 'jacket', 'pants', 'shirt', 'tie', 'shoes', 'belt', 'skirt', 'blouse' ] )
        params.select2 =
          width:       250
          placeholder: '희망 항목을 모두 선택해주세요.'
          allowClear:  true
          multiple:    true
        params.display = (value, sourceData) ->
          unless value
            $(this).empty()
            return
          mapped_values = []
          for i in value
            item = OpenCloset.category[i]
            continue unless item
            str = item.str.replace /^\s+|\s+$/, ""
            continue if str is ''
            mapped_values.push str
          $(this).html mapped_values.join(',')
        params.url = (params) ->
          url = $('#profile-user-info-data').data('url')
          data = {}
          data[params.name] = params.value.join(',')
          $.ajax url,
            type: 'PUT'
            data: data
      when 'user-pre_color'
        params.type    = 'select2'
        params.source  = ( { id: i, text: OpenCloset.color[i] } for i in [ 'staff', 'dark', 'black', 'navy', 'charcoalgray', 'gray', 'brown', 'etc' ] )
        params.select2 =
          width:                250
          placeholder:          '희망 색상을 선택해주세요.'
          allowClear:           true
          multiple:             true
          maximumSelectionSize: 3
        params.display = (value, sourceData) ->
          unless value
            $(this).empty()
            return
          mapped_values = []
          for i in value
            item = OpenCloset.color[i]
            continue unless item
            str = item.replace /^\s+|\s+$/, ""
            continue if str is ''
            mapped_values.push str
          $(this).html mapped_values.join(',')
        params.url = (params) ->
          url = $('#profile-user-info-data').data('url')
          data = {}
          data[params.name] = params.value.join(',')
          $.ajax url,
            type: 'PUT'
            data: data
      else
        params.type = 'text'

    $(el).editable params

  $.facebox.settings.loadingImage = '/lib/facebox/loading.gif'
  $.facebox.settings.closeImage = '/lib/facebox/closelabel.png'

  $('#user-address').click (e) ->
    e.preventDefault()
    $.facebox
      ajax: '/html/postcodify.html'

  $(document).bind 'reveal.facebox', ->
    $('#facebox #postcodify').postcodify
      api: '/api/postcode/search'
      timeout: 10000    # 10 seconds
      insertDbid: '.postcodify_dbid'
      insertAddress: '.postcodify_address'
      insertJibeonAddress: '.postcodify_jibeonaddress'
      searchButtonContent: '주소검색'
      onReady: ->
        $('#postcodify').find('.postcodify_search_controls.postcode_search_controls')
          .addClass('input-group').find('input[type=text]')
          .addClass('form-control').val($('.postcodify_address').val())
          .focus().end().find('button').addClass('btn btn-default btn-sm')
          .wrap('<span class="input-group-btn"></span>')
      afterSelect: (selectedEntry) ->
        $.ajax $('#profile-user-info-data').data('url'),
          type: 'PUT'
          data:
            address1: $('.postcodify_dbid').val()
            address2: $('.postcodify_address').val()
            address3: $('.postcodify_jibeonaddress').val()
          success:
            $('#user-address').text($('.postcodify_address').val())
        $(document).trigger('close.facebox')
      afterSearch: (keywords, results, lang, sort) ->
        $('summary.postcodify_search_status.postcode_search_status').hide()
