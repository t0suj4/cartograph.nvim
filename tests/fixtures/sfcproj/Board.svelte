<script>
  import { helperFn } from './util'

  let count = 0

  function bump() {
    count = helperFn(count)
  }
</script>

<p>{count}</p>
<button onclick={bump}>bump</button>
