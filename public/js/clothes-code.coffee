$ ->
  $('.order-status').each (i, el) ->
    $(el).addClass( OpenCloset.getStatusCss $(el).data('status') )
    $(el).find('.order-status-str').html('연체중') if $(el).data('late-fee') > 0

  $('.clothes-code').each (i, el) ->
    $(el).html OpenCloset.trimClothesCode $(el).html()

  #
  # inline editable field
  #
  $('.editable').each (i, el) ->
    params =
      mode:        'inline'
      showbuttons: 'true'
      emptytext:   '비어있음'
      pk:          $('#profile-clothes-info-data').data('pk')
      url: (params) ->
        url = $('#profile-clothes-info-data').data('url')
        data = {}
        data[params.name] = params.value
        $.ajax url,
          type: 'PUT'
          data: data

    switch $(el).attr('id')
      when 'clothes-category'
        params.type   = 'select'
        params.source = []
        params.source.push { value: category, text: OpenCloset.getCategoryStr(category) } for category in [
          'belt',
          'blouse',
          'coat',
          'hat',
          'jacket',
          'onepiece',
          'pants',
          'shirt',
          'shoes',
          'skirt',
          'tie',
          'waistcoat',
        ]
        params.display = (value) ->
          $(this).html OpenCloset.getCategoryStr(value)
      when 'clothes-gender'
        params.type    = 'select'
        params.source  = [
          { value: 'male',   text: "남성용"   },
          { value: 'female', text: "여성용"   },
          { value: 'unisex', text: "남녀공용" },
        ]
        params.display = (value) ->
          switch value
            when 'male'   then value_str = '남성용'
            when 'female' then value_str = '여성용'
            when 'unisex' then value_str = '남녀공용'
            else               value_str = ''
          $(this).html value_str
      when 'clothes-color'
        params.type   = 'select'
        params.source = []
        params.source.push { value: color, text: color_str } for color, color_str of OpenCloset.color
      else
        params.type = 'text'

    $(el).editable params
