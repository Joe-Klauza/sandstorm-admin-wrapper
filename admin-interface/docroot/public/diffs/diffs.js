$(document).ready(function () {
    options = {
      license: 'mpl',
      bgcolor: 'rgba(180, 180, 180, 0.0)',
      vpcolor: 'rgba(180, 180, 180, 0.0)',
      lhs_cmsettings: { readOnly: "nocursor" },
      cmsettings: { theme: 'monokai'},
      lhs: function(setValue) {
        setValue('the quick red fox\njumped over the hairy dog');
      },
      rhs: function(setValue) {
        setValue('the quick brown fox\njumped over the lazy dog');
      }
    }
    $('#mergely').mergely(options);
});
