require 'spec_helper'

module Spree
  describe OrderUpdater, type: :model do
    let(:order) { Spree::Order.create }
    let(:updater) { Spree::OrderUpdater.new(order) }

    context "order totals" do
      before do
        2.times do
          create(:line_item, order: order, price: 10)
        end
      end

      it "updates payment totals" do
        create(:payment_with_refund, order: order)
        Spree::OrderUpdater.new(order).update_payment_total
        expect(order.payment_total).to eq(40.75)
      end

      it "update item total" do
        updater.update_item_total
        expect(order.item_total).to eq(20)
      end

      it "update shipment total" do
        create(:shipment, order: order, cost: 10)
        updater.update_shipment_total
        expect(order.shipment_total).to eq(10)
      end

      context 'with order promotion followed by line item addition' do
        let(:promotion) { Spree::Promotion.create!(name: "10% off") }
        let(:calculator) { Calculator::FlatPercentItemTotal.new(preferred_flat_percent: 10) }

        let(:promotion_action) do
          Promotion::Actions::CreateAdjustment.create!({
            calculator: calculator,
            promotion: promotion,
          })
        end

        before do
          updater.update
          create(:adjustment, source: promotion_action, adjustable: order, order: order)
          create(:line_item, :order => order, price: 10) # in addition to the two already created
          updater.update
        end

        it "updates promotion total" do
          expect(order.promo_total).to eq(-3)
        end
      end

      it "update order adjustments" do
        # A line item will not have both additional and included tax,
        # so please just humour me for now.
        order.line_items.first.update_columns({
          adjustment_total: 10.05,
          additional_tax_total: 0.05,
          included_tax_total: 0.05,
        })
        updater.update_adjustment_total
        expect(order.adjustment_total).to eq(10.05)
        expect(order.additional_tax_total).to eq(0.05)
        expect(order.included_tax_total).to eq(0.05)
      end
    end

    context "updating shipment state" do
      before do
        allow(order).to receive_messages backordered?: false
      end

      it "is backordered" do
        allow(order).to receive_messages backordered?: true
        updater.update_shipment_state

        expect(order.shipment_state).to eq('backorder')
      end

      it "is nil" do
        updater.update_shipment_state
        expect(order.shipment_state).to be_nil
      end


      ["shipped", "ready", "pending"].each do |state|
        it "is #{state}" do
          create(:shipment, order: order, state: state)
          updater.update_shipment_state
          expect(order.shipment_state).to eq(state)
        end
      end

      it "is partial" do
        create(:shipment, order: order, state: 'pending')
        create(:shipment, order: order, state: 'ready')
        updater.update_shipment_state
        expect(order.shipment_state).to eq('partial')
      end
    end

    context "updating payment state" do
      let(:order) { Order.new }
      let(:updater) { order.updater }
      before { allow(order).to receive(:refund_total).and_return(0) }

      context 'no valid payments with non-zero order total' do
        it "is failed" do
          create(:payment, order: order, state: 'invalid')
          order.total = 1
          order.payment_total = 0

          updater.update_payment_state
          expect(order.payment_state).to eq('failed')
        end
      end

      context 'invalid payments are present but order total is zero' do
        it 'is paid' do
          order.payments << Spree::Payment.new(state: 'invalid')
          order.total = 0
          order.payment_total = 0

          expect {
            updater.update_payment_state
          }.to change { order.payment_state }.to 'paid'
        end
      end

      context "payment total is greater than order total" do
        it "is credit_owed" do
          order.payment_total = 2
          order.total = 1

          expect {
            updater.update_payment_state
          }.to change { order.payment_state }.to 'credit_owed'
        end
      end

      context "order total is greater than payment total" do
        it "is balance_due" do
          order.payment_total = 1
          order.total = 2

          expect {
            updater.update_payment_state
          }.to change { order.payment_state }.to 'balance_due'
        end
      end

      context "order total equals payment total" do
        it "is paid" do
          order.payment_total = 30
          order.total = 30

          expect {
            updater.update_payment_state
          }.to change { order.payment_state }.to 'paid'
        end
      end

      context "order is canceled" do

        before do
          order.state = 'canceled'
        end

        context "and is still unpaid" do
          it "is void" do
            order.payment_total = 0
            order.total = 30
            expect {
              updater.update_payment_state
            }.to change { order.payment_state }.to 'void'
          end
        end

        context "and is paid" do

          it "is credit_owed" do
            order.payment_total = 30
            order.total = 30
            create(:payment, order: order, state: 'completed', amount: 30)
            expect {
              updater.update_payment_state
            }.to change { order.payment_state }.to 'credit_owed'
          end

        end

        context "and payment is refunded" do
          it "is void" do
            order.payment_total = 0
            order.total = 30
            expect {
              updater.update_payment_state
            }.to change { order.payment_state }.to 'void'
          end
        end
      end

    end

    it "state change" do
      order.shipment_state = 'shipped'
      state_changes = double
      allow(order).to receive_messages state_changes: state_changes
      expect(state_changes).to receive(:create).with(
        previous_state: nil,
        next_state: 'shipped',
        name: 'shipment',
        user_id: nil
      )

      order.state_changed('shipment')
    end

    context "completed order" do
      before { allow(order).to receive_messages completed?: true }

      it "updates payment state" do
        expect(updater).to receive(:update_payment_state)
        updater.update
      end

      it "updates shipment state" do
        expect(updater).to receive(:update_shipment_state)
        updater.update
      end

      context 'with a shipment' do
        before { create(:shipment, order: order) }
        let(:shipment){ order.shipments[0] }

        it "updates each shipment" do
          expect(shipment).to receive(:update!)
          updater.update_shipments
        end

        it "refreshes shipment rates" do
          expect(shipment).to receive(:refresh_rates)
          updater.update_shipments
        end

        it "updates the shipment amount" do
          expect(shipment).to receive(:update_amounts)
          updater.update_shipments
        end
      end
    end

    context "incompleted order" do
      before { allow(order).to receive_messages completed?: false }

      it "doesnt update payment state" do
        expect(updater).not_to receive(:update_payment_state)
        updater.update
      end

      it "doesnt update shipment state" do
        expect(updater).not_to receive(:update_shipment_state)
        updater.update
      end

      it "doesnt update each shipment" do
        shipment = stub_model(Spree::Shipment)
        shipments = [shipment]
        allow(order).to receive_messages shipments: shipments
        allow(shipments).to receive_messages states: []
        allow(shipments).to receive_messages ready: []
        allow(shipments).to receive_messages pending: []
        allow(shipments).to receive_messages shipped: []

        allow(updater).to receive(:update_totals) # Otherwise this gets called and causes a scene
        expect(updater).not_to receive(:update_shipments).with(order)
        updater.update
      end
    end
  end
end
