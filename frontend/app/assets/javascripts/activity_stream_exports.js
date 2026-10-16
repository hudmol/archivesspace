(function() {
  document.getElementById('showCreateExportButton').addEventListener('click', function() {
    const $modal = AS.openCustomModal(
      'createExportModal',
      "Create an Activity Stream Export",
      AS.renderTemplate('create_export_popup_template', {}),
      'full',
      {},
      this,
    );

    $(document).trigger('initdatefields.aspace', [$modal]);

    $modal.find('#export_type').on('change', function() {
      const exportType = this.value;
      if (exportType === '') {
        $modal.find('#no_export_type').show();
        $modal.find('#export_criteria').hide();
      } else {
        $modal.find('#no_export_type').hide();
        $modal.find('#export_criteria').show();
        $modal.find('#export_criteria [data-supports]').each(function(){
          if ($(this).data('supports').includes(exportType)) {
            $(this).show();
            $(this).find(":input").each(function(){
              $(this).prop('disabled', false);
            });
          } else {
            $(this).hide();
            $(this).find(":input").each(function(){
              $(this).prop('disabled', true);
            });
          }
        });
      }
    });

    $modal.find('form').on('submit', function(e) {
      e.preventDefault();
      $modal.find('.modal-footer .btn').prop('disabled', true);

      $modal.find('#generalError').hide();

      fetch($(this).attr('action'), {
        method: 'POST',
        body: new FormData(this),
      })
      .then(response => response.json())
      .then(data => {
        if (data.status === 'SUCCESS') {
          console.log("SUCCESS!");
          console.log(data);
          window.location.reload();
        } else {
          console.log("ERROR!");
          console.log(data);
          $modal.find('#generalError').show();
          $modal.find('.modal-footer .btn').prop('disabled', false);
        }
      });
    });


  });
})();