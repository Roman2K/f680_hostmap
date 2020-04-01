$:.unshift __dir__
require 'minitest/autorun'
require 'gen'

class LabelsTest < Minitest::Test
  def test_lookup
    labels = Labels.new \
      'traefik.enable' => 'True'

    assert_equal 'True', labels.lookup('traefik.enable')
    assert_equal 'True', labels.lookup('traefik', 'enable')
    assert_nil labels.lookup("traefik", "x")
    assert_nil labels.lookup("x", "x")
    assert_nil labels.lookup("x")

    exc = assert_raises RuntimeError do
      labels.lookup 'traefik.enable.xxx'
    end
    assert_match /label at traefik.enable is not a hash/, exc.message
  end
end
