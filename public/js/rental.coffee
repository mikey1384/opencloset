$ ->
  $('#query').focus()
  $('#btn-clear').click (e) ->
    e.preventDefault()
    $('#clothes-list ul li').remove()
    $('#action-buttons').hide()
    $('#query').focus()
  $('#btn-search').click (e) ->
    $('#search-form').trigger('submit')

  $('#search-form').submit (e) ->
    e.preventDefault()
    query = $('#query').val()
    $('#query').val('').focus()
    return unless query

    #
    # 검색어 길이가 4이면
    #
    if ( query.length is 4 )
      #
      # 의류 검색 및 결과 테이블 갱신
      #
      $.ajax "/api/clothes/#{query}.json",
        type: 'GET'
        dataType: 'json'
        success: (data, textStatus, jqXHR) ->
          data.code        = data.code.replace /^0/, ''
          data.categoryStr = OpenCloset.getCategoryStr data.category
          if data.status is '대여중'
            return if $("#clothes-table table tbody tr[data-order-id='#{data.order.id}']").length
            compiled = _.template($('#tpl-row-checkbox-disabled').html())
            $html = $(compiled(data))
            #if data.order.overdue
            #  compiled = _.template($('#tpl-overdue-paragraph').html())
            #  html     = compiled(data)
            #  $html.find("td:last-child").append(html)
          else
            return if $("#clothes-table table tbody tr[data-clothes-code='#{data.code}']").length
            compiled = _.template($('#tpl-row-checkbox-enabled').html())
            $html = $(compiled(data))
            $('#action-buttons').show() if data.status is '대여가능'

          $html.find('.order-status').addClass(OpenCloset.getStatusCss data.status)
          $("#clothes-table table tbody").append($html)
        error: (jqXHR, textStatus, errorThrown) ->
          alert('error', jqXHR.responseJSON.error)
        complete: (jqXHR, textStatus) ->
    #
    # 사용자 검색 및 결과 테이블 갱신
    #
    $.ajax '/api/search/user.json',
      type: 'GET'
      data: { q: query }
      dataType: 'json'
      success: (data, textStatus, jqXHR) ->
      error: (jqXHR, textStatus, errorThrown) ->
        alert('error', jqXHR.responseJSON.error)
      complete: (jqXHR, textStatus) ->

  #
  # 의류 검색 결과 테이블에서 모든 항목 선택 및 취소
  #
  $('#input-check-all').click (e) ->
    is_checked = $('#input-check-all').is(':checked')
    $(@).closest('thead').next().find('.ace:checkbox:not(:disabled)').prop('checked', is_checked)

  #
  # 대여 버튼 클릭
  #
  $('#action-buttons').on 'click', 'button:not(.disabled)', (e) ->
    unless $('input[name=gid]:checked').val()
      return alert('대여자님을 선택해 주세요')
    unless $('input[name=clothes-code]:checked').val()
      return alert('선택하신 주문상품이 없습니다')
    $('#order-form').submit()
